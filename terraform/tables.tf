# The four tabletops. Each one becomes:
#   - its own Tailscale node  (tt-<key>)  carrying its own ACL tag (tag:tt-<key>)
#   - its own Foundry container (host/docker-compose.yml must define ts-<key> and foundry-<key>)
#
# One node per table is what makes per-campaign sharing possible: you share a
# *node* with a *person*, so four campaigns need four nodes.
locals {
  tables = {
    dnd         = { title = "Dungeons & Dragons 5e", system = "dnd5e" }
    daggerheart = { title = "Daggerheart", system = "daggerheart" }
    pf2e        = { title = "Pathfinder 2e", system = "pf2e" }
    sf2e        = { title = "Starfinder 2e", system = "sf2e" }
  }

  node_name = { for k, _ in local.tables : k => "tt-${k}" }
  node_tag  = { for k, _ in local.tables : k => "tag:tt-${k}" }
  host_tag  = "tag:tt-host"
  host_name = "tt-host"
  table_url = { for k, n in local.node_name : k => "https://${n}.${var.tailnet_domain}" }
}
