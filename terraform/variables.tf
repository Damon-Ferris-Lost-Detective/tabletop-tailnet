variable "name" {
  description = "Name prefix for AWS resources and the SSM parameter path (/<name>/...)."
  type        = string
  default     = "tabletop"
}

variable "aws_region" {
  description = "AWS region. ca-central-1 (Montreal) is the closest region to Ontario."
  type        = string
  default     = "ca-central-1"
}

variable "instance_type" {
  description = "Graviton (arm64) instance. t4g.medium (4 GiB) comfortably runs 2-3 Foundry worlds; use t4g.large for all four at once."
  type        = string
  default     = "t4g.medium"
}

variable "data_volume_gb" {
  description = "Size of the persistent EBS volume holding worlds, assets and Tailscale node identities."
  type        = number
  default     = 30
}

variable "timezone" {
  type    = string
  default = "America/Toronto"
}

variable "tailnet_domain" {
  description = "Your tailnet's MagicDNS suffix, e.g. tail1234.ts.net (Tailscale admin console > DNS)."
  type        = string
}

variable "admin_email" {
  description = "Tailscale login of the GM / tailnet owner. Gets access to every table and SSH to the host."
  type        = string
}

variable "foundry_username" {
  description = "foundryvtt.com username (used by the container to download and license Foundry)."
  type        = string
  sensitive   = true
}

variable "foundry_password" {
  description = "foundryvtt.com password. Avoid single quotes (')."
  type        = string
  sensitive   = true
}

variable "foundry_admin_key" {
  description = "Foundry setup-screen admin password (shared by all four instances)."
  type        = string
  sensitive   = true
}

variable "foundry_license_keys" {
  description = <<-EOT
    License key per table, e.g. { pf2e = "AAAA-BBBB-..." }.
    Foundry allows ONE player-accessible instance per license, so one key = one table open at a time.
    Tables without a key can still be created but cannot be opened.
  EOT
  type        = map(string)
  sensitive   = true
  default     = {}
}
