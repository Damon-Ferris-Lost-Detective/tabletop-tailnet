# ---------------------------------------------------------------------------
# Access policy (the whole security model lives here, in version control)
# ---------------------------------------------------------------------------
locals {
  table_dsts = [for k, t in local.node_tag : "${t}:443"]

  policy = {
    tagOwners = merge(
      { (local.host_tag) = [var.admin_email] },
      { for k, t in local.node_tag : t => [var.admin_email] },
    )

    acls = [
      # The GM: every table's HTTPS port, plus SSH to the host.
      {
        action = "accept"
        src    = [var.admin_email]
        dst    = concat(local.table_dsts, ["${local.host_tag}:22"])
      },
      # Players arrive as "shared" users (their own tailnet + a shared node).
      # They are limited to HTTPS on nodes that were individually shared with
      # them. Which table(s) they get is decided by the share, not by this rule.
      {
        action = "accept"
        src    = ["autogroup:shared"]
        dst    = local.table_dsts
      },
      # Nothing else is allowed, so tables cannot talk to each other or to the
      # host: a compromised Foundry module is contained to its own node.
    ]

    ssh = [
      {
        action = "accept"
        src    = [var.admin_email]
        dst    = [local.host_tag]
        users  = ["ubuntu", "root"]
      },
    ]

    # Policy tests run on every apply. A bad edit is rejected, not deployed.
    tests = concat(
      [
        {
          src    = var.admin_email
          accept = concat(local.table_dsts, ["${local.host_tag}:22"])
          deny   = ["${local.host_tag}:443", "${local.host_tag}:80"]
        },
      ],
      [
        for k, t in local.node_tag : {
          src  = t
          deny = concat(
            [for k2, t2 in local.node_tag : "${t2}:443" if k2 != k],
            ["${local.host_tag}:22", "${local.host_tag}:443"],
          )
        }
      ],
    )
  }
}

resource "tailscale_acl" "this" {
  acl                        = jsonencode(local.policy)
  overwrite_existing_content = true # this repo owns the policy file for the demo tailnet
}

# ---------------------------------------------------------------------------
# Tagged, pre-authorised auth keys: one per node, so each can be revoked alone.
# A node authenticated with a tagged key is owned by the tag, not by a person,
# so it never needs re-login and its key does not expire.
# (If your provider version has renamed this resource to tailscale_key, rename
# it here; the arguments are the same.)
# ---------------------------------------------------------------------------
resource "tailscale_tailnet_key" "table" {
  for_each = local.tables

  description         = "${var.name} ${each.key} sidecar"
  reusable            = false
  ephemeral           = false
  preauthorized       = true
  expiry              = 3600 * 24 * 30
  tags                = [local.node_tag[each.key]]
  recreate_if_invalid = "always"

  depends_on = [tailscale_acl.this]
}

resource "tailscale_tailnet_key" "host" {
  description         = "${var.name} host (Tailscale SSH)"
  reusable            = false
  ephemeral           = false
  preauthorized       = true
  expiry              = 3600 * 24 * 30
  tags                = [local.host_tag]
  recreate_if_invalid = "always"

  depends_on = [tailscale_acl.this]
}
