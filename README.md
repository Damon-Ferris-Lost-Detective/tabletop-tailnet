# Tabletop Tailnet: four Foundry VTT game tables behind Tailscale, on AWS

**Tailnet name:** `TODO-your-tailnet.ts.net`  &nbsp;|&nbsp; **Region:** `ca-central-1` &nbsp;|&nbsp; **Status:** see [Honest status](#honest-status-read-this-first)

## 1. What I built

Four independent virtual tabletops (D&D 5e, Daggerheart, Pathfinder 2e, Starfinder 2e) running on a single small AWS instance. **Nothing is reachable from the public internet**: the security group has zero inbound rules, and every table is its own Tailscale node with its own HTTPS certificate and its own ACL tag.

Access rotates without exceeding the free plan's 6 users. Players are not invited into the tailnet. They use their own free Tailscale accounts and a table's node is *shared* with them. A roster file (`access/roster.toml`) is the source of truth for who can reach which table, and a small tool (`access/rotate.py`, also run from CI) reconciles it.

## 2. Why this use case

Providing secure access to Foundry VTT is a challenge when deployed "normally" to the GM's personal device that lacks SSL, opening a attack vector to them, and limits access to only when Foundry is active on the device.
The practical concern for a business is one of customer when they have a **changing set of external parties** (contractors, partners, auditors, a client's team) that access to **specific internal applications** with limited capability:


| Customer problem | Tabletop equivalent |
|---|---|
| Expose an internal app without opening ports or running a bastion | Foundry has no public port; security group has no inbound rules |
| Per-seat licensing means external collaborators are expensive or slow to onboard | Free plan caps at 6 users; shared nodes don't consume seats |
| Different outsiders need different apps | Different players need different campaigns |
| Access must expire and be auditable | Roster in git, plan/apply in CI, ACL tests on every change |
| A compromised app must not become a foothold | Per-app tags, no tag-to-tag rules |

It is small enough to explain in a minute and real enough that I will actually use it.

## 3. Architecture

Full diagrams and the layered-controls table are in [`docs/architecture.md`](docs/architecture.md). In short:

```
Player (own tailnet) ──shared node──┐
GM (owner) ─────────────────────────┤  WireGuard (direct, DERP fallback)
                                    ▼
 EC2 t4g.medium, SG: 0 inbound  ┌──────────────────────────────────────────┐
                                │ ts-pf2e  (tag:tt-pf2e)  Serve :443 TLS   │
                                │    └─ foundry-pf2e  127.0.0.1:30000       │  x4 tables
                                │ tailscaled (tag:tt-host)  Tailscale SSH   │
                                └──────────────────────────────────────────┘
                                EBS /data (encrypted, daily snapshots)   SSM (secrets)
```

Key choices, each with the trade-off:

- **One Tailscale node per table (sidecar container), not one node for the host.** Sharing is node-to-person. Four campaigns with different players need four nodes. Cost: four tiny `tailscaled` processes; benefit: per-campaign sharing and per-campaign blast radius.
- **Foundry shares the sidecar's network namespace** (`network_mode: service:ts-x`) and publishes no ports. Cost: if the sidecar restarts, Foundry must too (compose handles this); benefit: no accidental host exposure, and Docker cannot bypass a firewall that doesn't exist.
- **Tailscale Serve for HTTPS.** Foundry's audio/video needs a secure context, and Serve gives a real certificate for `*.ts.net` with no reverse proxy or certbot.
- **Userspace networking in the sidecars.** No `NET_ADMIN`, no `/dev/net/tun`, less privilege. Throughput is plenty for map images and websockets.
- **Public subnet, no NAT gateway.** A NAT gateway costs more per month than the instance. With zero inbound rules the public IP is egress-only. With more time I would use a private subnet plus VPC endpoints.
- **Secrets in SSM Parameter Store**, read by the instance role at boot, instead of user-data (which is readable from the console).
- **State on a separate EBS volume**, so the instance is disposable (`user_data_replace_on_change`) and node identities survive.
- **Tagged auth keys.** Nodes are owned by tags, not people, so they never need a human to re-authenticate and their keys don't expire.

## 4. The 6-seat rotation model

| | Invite user into tailnet | **Share a node (used here)** |
|---|---|---|
| Uses one of the 6 free seats | Yes | **No** |
| Sees the whole tailnet (limited by ACL) | Yes | **Only that node** |
| Player needs a Tailscale account | Yes (in your tailnet) | Yes (their own, free) |
| Per-person ACL rules | Yes | No (one `autogroup:shared` rule for everyone shared) |
| Per-person revoke via API | n/a | Cancel *pending* invites yes; **accepted shares: console** (see limitation) |

Rotation workflow:

1. Edit `access/roster.toml` (add/remove an email under a table).
2. `make rotate-plan` shows `INVITE`, `CANCEL`, and `REVOKE MANUALLY` lines.
3. `make rotate-apply` sends invites and cancels stale pending ones.
4. For players who already accepted and have rotated out, remove the share in the admin console (Machines > node > Share). The tool tells you exactly who and where.
5. `make seats` confirms the member count is at or below 6. CI runs this on every change (`.github/workflows/access.yml`).

A second rotation lever is operational: `sudo tabletop open|close|switch <table>` turns a table's Foundry on or off. Foundry licenses allow one player-accessible instance per license key, so `open` refuses to start a second table on the same key.

### Single-license mode (one table open at a time)

If you own one Foundry license, run it this way. The architecture is unchanged; only the settings differ:

1. In `terraform.tfvars`, put the **same key under all four tables**. `tabletop open` looks the license up per table, so a table with no key listed cannot be opened. With the same key everywhere, it refuses to start a second table.
2. Use a smaller instance: `instance_type = "t4g.small"` (2 GiB). One Foundry process plus four idle sidecars fits; swap is already configured. Check current pricing in the AWS calculator.
3. Switch campaigns with one command: `sudo tabletop switch pf2e` closes whatever is open, then opens Pathfinder. (`switch` checks that the target has a license before closing anything.)
4. Closed tables keep their Tailscale node online, so shares and invites keep working. A shared player who visits a closed table gets a gateway error from the node, not a Foundry page.
5. Stop the instance between sessions; storage is then the only cost.

The alternative is one Foundry instance with four worlds (one node, one URL). It is simpler to run but gives up per-campaign sharing and isolation, which is the core of this demo, so this repo keeps four nodes.

## 5. Prerequisites and assumptions

- AWS account and credentials (`aws configure` or SSO), Terraform or OpenTofu >= 1.5, Python 3.11+, Docker (only for the offline checks).
- A Tailscale account on the **Personal (free)** plan. Personal is for non-commercial use, which is true of a home game.
- In the Tailscale admin console > DNS: **MagicDNS on** and **HTTPS Certificates enabled** (Serve needs both).
- A Tailscale API key (`tskey-api-...`, expires in <= 90 days) exported as `TAILSCALE_API_KEY` for Terraform and `TS_API_KEY` for `rotate.py`. I used one user-owned key for both because creating *share invites* needs a user-owned credential. OAuth clients are the better choice for Terraform alone.
- A foundryvtt.com account with at least one license. **One key = one table open at a time**; four simultaneously accessible tables need four keys. Confirm current terms at foundryvtt.com/article/license.
- Foundry systems are installed from Foundry's own setup screen (the one manual step, see below). Image tag is pinned to Foundry `13` by default; check each system's compatibility before moving to 14.

## 6. Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars      # fill in; git-ignored
export TAILSCALE_API_KEY=tskey-api-...            # the provider reads these
export TAILSCALE_TAILNET=-                        # "-" = key's default tailnet
cd .. && make init && make plan && make apply
```

`apply` does, in order: ACL + policy tests -> one tagged auth key per node -> VPC, SG (no inbound), IAM, SSM parameters -> encrypted data volume + daily snapshots -> EC2 instance whose cloud-init installs Docker/Tailscale/AWS CLI, mounts the data volume, pulls secrets, joins the tailnet, and starts the four sidecars.

Then:

```bash
make ssh                                  # tailscale ssh ubuntu@tt-host (no keys, no port 22)
sudo tabletop status
sudo tabletop open pf2e                   # needs a license key for that table
```

**First run of each table (manual, one time):** open `https://tt-<table>.<tailnet>.ts.net`, accept the Foundry EULA, enter the admin key, then in *Setup > Game Systems > Install System*:

| Table | System | How |
|---|---|---|
| `dnd` | Dungeons & Dragons Fifth Edition (`dnd5e`) | search in the installer |
| `daggerheart` | Foundryborne Daggerheart | search "Foundryborne", or manifest `https://raw.githubusercontent.com/Foundryborne/daggerheart/refs/heads/main/system.json` |
| `pf2e` | Pathfinder Second Edition | search in the installer |
| `sf2e` | Starfinder Second Edition | search in the installer (published at foundryvtt.com/packages/sf2e) |

Automating this (for example by pre-seeding each `/data/foundry/<table>/Data/systems`) is on the "more time" list.

Add players: put their emails in `roster.toml`, then `make rotate-apply`. They accept the emailed invite from their own Tailscale account and open the table URL.

Tear down: `make destroy` (the data volume has `prevent_destroy`; remove that block deliberately if you really want it gone).

## 7. Validate

```bash
make validate     # writes docs/evidence/validation-<timestamp>.txt
```

| # | Check | Expected |
|---|---|---|
| 1 | All five nodes online with their tags | `tt-host`, `tt-dnd`, `tt-daggerheart`, `tt-pf2e`, `tt-sf2e` |
| 2 | `tailscale ping tt-host` | answers; shows direct path or DERP region |
| 3 | `curl https://tt-<table>.<tailnet>/api/status` per table | 200 with Foundry's version (SKIP, not FAIL, if the table is closed) |
| 4 | Public ports 22/80/443/30000 on the instance's public IP; SG ingress count | all closed; 0 inbound rules |
| 5 | `tailscale ssh ubuntu@tt-host` | works with no keys |
| 6 | From inside `ts-dnd`, ping `tt-pf2e` | **fails** (isolation) |
| 7 | ACL `tests` block | evaluated on every `terraform apply`; failing test blocks the change |
| 8 | `make rotate-plan` before/after editing the roster; second account opens a shared table | plan converges; shared player reaches only their table |

Evidence checklist: [`docs/evidence/README.md`](docs/evidence/README.md).

## 8. Why Tailscale vs. the traditional options

| Approach | What it takes | Where it hurts for this use case |
|---|---|---|
| **Port-forward / public IP + reverse proxy** | Open 443, TLS certs, rate limiting, auth in front of Foundry | Foundry's login is a shared-ish world password; every scanner on the internet can reach it |
| **Bastion host** | Open 22, manage keys, tunnel each app | Per-person keys to rotate; players are not engineers; no per-app scoping |
| **Traditional VPN (OpenVPN/WireGuard concentrator)** | Run a gateway, issue configs, route/DNS setup | A listening port, hand-managed peers, all-or-nothing network access, someone is on call for it |
| **Cloud security-group allow-lists** | Collect each player's IP | Home IPs change; mobile/travel breaks; manual edits |
| **Tailscale (this repo)** | Install the client; share a node | Identity-based, no inbound ports, per-app ACLs as code, per-person sharing, direct paths with encrypted relay fallback |

How I would explain it to someone new: *"Your service has no public address at all. People get to it through an encrypted private path that only exists for the specific person and the specific service you chose, and you can see and change that list in a file."*

## 9. Cost (estimates, verify before committing)

Rough monthly figures for ca-central-1; check the AWS pricing calculator: t4g.medium on-demand roughly mid-$20s USD if left running 24/7, plus about $4-5 for ~46 GB of gp3 and a little for snapshots. Stopping the instance between sessions leaves only storage costs. Tailscale and the sidecars are free; Foundry licenses are a one-time purchase each.

## 10. Honest status (read this first)

This repository was authored with AI assistance and **has not yet been applied to a real AWS account or Tailscale tailnet**. What was verified offline, and what was not:

| Verified here | How |
|---|---|
| `host/docker-compose.yml` renders; only the four sidecars start by default; each Foundry service attaches to its sidecar and picks up its own license and hostname | `docker compose config` with a dummy `.env` |
| SSM-to-`.env` transform and the `tabletop` CLI's key extraction | run against sample JSON |
| `rotate.py` plan / apply / seats / validation logic | exercised end-to-end against a **mock** Tailscale API (not the real one) |
| Shell syntax, JSON, TOML, YAML | `bash -n`, parsers |

| **Not** verified | Risk |
|---|---|
| `terraform validate/plan/apply` | Terraform/OpenTofu were not available; HCL was reviewed by hand only |
| Tailscale provider resource names | I used `tailscale_tailnet_key`; newer provider docs mention `tailscale_key`. Rename if `init`/`plan` complains |
| Real Tailscale API response shapes for device invites | Written from the public API docs; field names (`acceptedBy.loginName`, `invites` envelope) may need adjusting |
| That an accepted share cannot be revoked by API | From third-party client docs; check https://tailscale.com/api |
| Shared-node MagicDNS name resolving in a player's tailnet (`tt-x.<owner-tailnet>.ts.net`) | Expected from Tailscale's sharing docs; confirm with a real second account |
| felddy image data-dir ownership (`uid 421`) | Assumed default; adjust `bootstrap.sh` if Foundry cannot write `/data` |
| Foundry + system version compatibility on tag `13` | Check each system's compatibility page |

**Before submitting:** deploy, run `make validate`, commit the evidence, and replace the TODOs below with what actually happened.

## 11. What worked well / what was difficult or surprising / what I'd do differently

> **TODO (yours):** these three subsections are for your real experience after deploying. Don't ship them as-is. Prompts below are things worth confirming or refuting, based on what looked risky while designing.

**What worked well:** _TODO_

**What was difficult or surprising:** _TODO. Candidates to check: (a) the license model forcing "one table open per key"; (b) accepted shares not being revocable via API; (c) whether Tailscale Serve inside a sidecar needed anything beyond `TS_SERVE_CONFIG`; (d) first-boot timing with cloud-init._

**What I would do differently with more time:**
- Private subnet + VPC endpoints instead of a public IP with no inbound.
- Pre-seed Foundry systems/modules from a manifest list so tables are fully automated.
- Replace the user API key with an OAuth client / workload identity federation for Terraform and CI, keeping the user key only for share invites.
- Remote Terraform state (S3 + KMS) since SSM values pass through state.
- Tailscale device posture or approval flows for GM devices; webhooks to alert when a new node or share appears.
- Scheduled stop/start of the instance around game nights.
- A Tailscale Kubernetes variant for comparison.

## 12. AI assistance disclosure

> **TODO (yours):** edit this to be true for you. The assignment asks what you used AI for, what you reviewed or changed, where it helped, and where it was wrong.

- **What I used AI for:** Claude (Anthropic) was used for research of Tailscale sharing/API/ACL behaviour and Foundry licensing, and to draft the Terraform, cloud-init/bootstrap, compose file, `rotate.py`, validation script, CI workflow, and this README.
- **What the AI checked itself:** compose rendering, shell/JSON/TOML/YAML syntax, `rotate.py` against a mock API (see section 10).
- **What I reviewed or changed:** _TODO_
- **Where it was helpful:** _TODO_
- **Where it was wrong, incomplete or misleading:** _TODO. One example from authoring: an early draft iterated `for_each` over a map containing sensitive values, which Terraform rejects; it was changed to iterate over key names. Add the ones you find._

## 13. Repository layout

```
terraform/        AWS + Tailscale (ACL with tests, tagged keys, VPC, IAM, SSM, EBS, DLM, EC2)
host/             docker-compose (4 sidecars + 4 Foundry), serve.json, bootstrap.sh, tabletop CLI
access/           roster.toml and rotate.py (share reconciliation + seat audit)
scripts/          validate.sh
docs/             architecture.md, evidence/
.github/          access-rotation workflow
Makefile          init/plan/apply/validate/rotate-plan/rotate-apply/seats/ssh/check
```
