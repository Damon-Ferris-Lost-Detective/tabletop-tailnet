data "aws_caller_identity" "me" {}
data "aws_availability_zones" "ok" { state = "available" }

# Ubuntu 24.04 LTS, arm64 (Graviton), resolved through Canonical's public SSM parameter.
data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# ---------------------------------------------------------------------------
# Network: one public subnet, NO inbound rules.
# The instance reaches Tailscale's coordination/relay servers outbound; players
# reach it through the tailnet. Nothing on the public internet can connect in.
# A NAT gateway (~$33/mo) would add nothing here, so the instance gets a public
# IP for egress only.
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/24"
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.0.0/26"
  availability_zone       = data.aws_availability_zones.ok.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "host" {
  name        = "${var.name}-host"
  description = "No inbound. Egress only; access is via Tailscale."
  vpc_id      = aws_vpc.this.id

  # Deliberately no ingress blocks.

  egress {
    description = "All outbound (Tailscale, Docker registries, foundryvtt.com, apt)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Secrets: SSM Parameter Store (SecureString). The instance role may read only
# /<name>/*, so nothing sensitive is baked into user_data or the AMI.
# NOTE: values also live in Terraform state; keep state private (see README).
# ---------------------------------------------------------------------------
locals {
  foundry_secrets = {
    username  = var.foundry_username
    password  = var.foundry_password
    admin_key = var.foundry_admin_key
  }
}

resource "aws_ssm_parameter" "foundry" {
  # for_each must not see sensitive values, so iterate over the (public) key names.
  for_each = toset(nonsensitive(keys(local.foundry_secrets)))
  name     = "/${var.name}/foundry/${each.key}"
  type     = "SecureString"
  value    = local.foundry_secrets[each.key]
}

resource "aws_ssm_parameter" "license" {
  for_each = toset(nonsensitive(keys(var.foundry_license_keys)))
  name     = "/${var.name}/license/${each.key}"
  type     = "SecureString"
  value    = var.foundry_license_keys[each.key]

  lifecycle {
    precondition {
      condition     = contains(keys(local.tables), each.key)
      error_message = "foundry_license_keys has a key that is not one of: ${join(", ", keys(local.tables))}."
    }
  }
}

resource "aws_ssm_parameter" "tskey_table" {
  for_each = local.tables
  name     = "/${var.name}/tskey/${each.key}"
  type     = "SecureString"
  value    = tailscale_tailnet_key.table[each.key].key
}

resource "aws_ssm_parameter" "tskey_host" {
  name  = "/${var.name}/tskey/host"
  type  = "SecureString"
  value = tailscale_tailnet_key.host.key
}

# ---------------------------------------------------------------------------
# Instance role: read its own parameters; SSM Session Manager as break-glass
# (works over outbound HTTPS, so still no inbound port).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${var.name}-host"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "read_params" {
  statement {
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.me.account_id}:parameter/${var.name}/*"]
  }
  # SecureStrings use the AWS-managed aws/ssm key; its key policy lets principals
  # with ssm:GetParameter decrypt, so no explicit kms:Decrypt is needed.
}

resource "aws_iam_role_policy" "read_params" {
  name   = "read-own-parameters"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.read_params.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name}-host"
  role = aws_iam_role.host.name
}

# ---------------------------------------------------------------------------
# Persistent data volume. The instance is disposable; this is not.
# ---------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  tags = {
    Name   = "${var.name}-data"
    Backup = "daily"
  }

  lifecycle { prevent_destroy = true }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.host.id
}

# Daily snapshots, 7 kept, for any volume tagged Backup=daily.
data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.name}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "${var.name} daily snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Backup = "daily" }

    schedule {
      name = "daily-7"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["08:00"] # UTC
      }
      retain_rule { count = 7 }
      copy_tags = true
    }
  }
}

# ---------------------------------------------------------------------------
# The host
# ---------------------------------------------------------------------------
resource "aws_instance" "host" {
  ami                    = data.aws_ssm_parameter.ubuntu_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach the metadata service
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 16
    encrypted   = true
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    region         = var.aws_region
    name           = var.name
    volume_id      = aws_ebs_volume.data.id
    timezone       = var.timezone
    tailnet_domain = var.tailnet_domain
    tables         = join(" ", keys(local.tables))
    host_name      = local.host_name
    compose_b64    = base64gzip(file("${path.module}/../host/docker-compose.yml"))
    serve_b64      = base64gzip(file("${path.module}/../host/serve.json"))
    bootstrap_b64  = base64gzip(file("${path.module}/../host/bootstrap.sh"))
    cli_b64        = base64gzip(file("${path.module}/../host/tabletop.sh"))
  })
  user_data_replace_on_change = true # safe: all state is on the data volume

  tags = { Name = "${var.name}-host" }

  depends_on = [
    aws_ssm_parameter.foundry,
    aws_ssm_parameter.license,
    aws_ssm_parameter.tskey_table,
    aws_ssm_parameter.tskey_host,
    aws_iam_role_policy.read_params,
    aws_route_table_association.public,
  ]
}
