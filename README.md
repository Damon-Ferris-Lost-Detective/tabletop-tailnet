# Tabletop Tailnet: four Foundry VTT game tables behind Tailscale, on AWS

**Tailnet:** `tail96c8bb.ts.net` | **Region:** `us-east-2` | **Instance:** `t4g.small` | **Status:** see [Honest status](#10-honest-status)

## 1. What I built

Four independent virtual tabletops (D&D 5e, Daggerheart, Pathfinder 2e, Starfinder 2e) on one small AWS instance. **Nothing is reachable from the public internet**: the security group has zero inbound rules, and each table is its own Tailscale node with its own HTTPS certificate and ACL tag.

Access rotates without exceeding the free plan's 6 users. Players are not invited into the tailnet. They use their own free Tailscale accounts, and a table's node is *shared* with them. `access/roster.toml` is the source of truth for who can reach which table, and `access/rotate.py` (also run from CI) reconciles it.

## 2. Why this use case

Foundry VTT is usually run on the GM's own device, which lacks SSL, exposes the GM to attack, and is only reachable while the device is on. The business version of the problem is a **changing set of external parties** (contractors, partners, auditors, a client's team) who need **specific internal applications** with limited capability:

| Customer problem | Tabletop equivalent |
|---|---|
| Expose an internal app without opening ports or running a bastion | No public port; security group has no inbound rules |
| Per-seat licensing makes outside collaborators costly or slow to onboard | Free plan caps at 6 users; shared nodes don't consume seats |
| Different outsiders need different apps | Different players need different campaigns |
| Access must expire and be auditable | Roster in git, plan/apply in CI, ACL tests on every change |
| A compromised app must not become a foothold | Per-app tags, no tag-to-tag rules |

It is small enough to explain quickly and real enough that I will actually use it.

## 3. Architecture

Full diagrams and the layered-controls table: [`docs/architecture.md`](docs/architecture.md).

```
Player (own tailnet) --shared node--+
GM (owner) -------------------------+  WireGuard (direct, DERP fallback)
                                    v
 EC2 t4g.small, SG: 0 inbound   ts-pf2e (tag:tt-pf2e)  Serve :443 TLS
                                  +- foundry-pf2e 127.0.0.1:30000       x4 tables
                                tailscaled (tag:tt-host)  Tailscale SSH
                                EBS /data (encrypted, daily snapshots)   SSM (secrets)
```

Key choices and trade-offs:

- **One Tailscale node per table (sidecar), not one for the host.** Sharing is node-to-person, so four campaigns with different players need four nodes. Cost: four tiny `tailscaled` processes. Benefit: per-campaign sharing and blast radius.
- **Foundry shares the sidecar's network namespace** and publishes no ports. If the sidecar restarts, Foundry must too (compose handles it). No accidental host exposure.
- **Tailscale Serve for HTTPS.** Foundry's audio/video needs a secure context. Serve gives a real `*.ts.net` certificate with no reverse proxy or certbot.
- **Userspace networking in the sidecars.** No `NET_ADMIN` or `/dev/net/tun`, so less privilege. Throughput is plenty for maps and websockets.
- **Public subnet, no NAT gateway.** A NAT gateway costs more than the instance, and with zero inbound rules the public IP is egress-only. A private subnet plus VPC endpoints would be better.
- **Secrets in SSM Parameter Store**, read by the instance role at boot, not in user-data (readable from the console).
- **State on a separate EBS volume**, so the instance is disposable (`user_data_replace_on_change`) and node identities survive.
- **Tagged auth keys.** Nodes are owned by tags, not people, so they never need re-authentication and their keys don't expire.

## 4. The 6-seat rotation model

I **share a node** instead of inviting users into the tailnet. A shared player uses no seat, sees only that node, and needs their own free Tailscale account. The trade-off is that per-person ACL rules aren't possible (one `autogroup:shared` rule covers everyone shared), and pending invites can be cancelled by API but **accepted shares must be revoked in the console**.

1. Edit `access/roster.toml` (add or remove an email under a table).
2. `make rotate-plan` shows `INVITE`, `CANCEL` and `REVOKE MANUALLY` lines.
3. `make rotate-apply` sends invites and cancels stale pending ones.
4. For rotated-out players who already accepted, remove the share in the admin console (Machines > node > Share). The tool says who and where.
5. `make seats` confirms the member count is 6 or fewer. CI runs this on every change (`.github/workflows/access.yml`).

A second lever is operational: `sudo tabletop open|close|switch <table>`. **One Foundry license means one player-accessible table at a time**, and `open` refuses to start a second table on the same key. For single-license mode:

1. Put the **same key under all four tables** in `terraform.tfvars`.
2. Use `instance_type = "t4g.small"` (2 GiB). One Foundry process plus four idle sidecars fits.
3. Switch campaigns with `sudo tabletop switch pf2e`, which checks the target has a license before closing anything.
4. Closed tables keep their Tailscale node online, so shares keep working. A player visiting a closed table gets a gateway error (502), not a Foundry page.
5. Stop the instance between sessions; storage is then the only cost.

The alternative, one Foundry instance with four worlds, is simpler but gives up per-campaign sharing and isolation, which is the point of this demo.

## 5. Prerequisites

- AWS credentials, Terraform or OpenTofu >= 1.5, Python 3.11+.
- Tailscale **Personal (free)** plan (non-commercial use). In the admin console > DNS, turn on **MagicDNS** and **HTTPS Certificates**.
- A Tailscale API key (`tskey-api-...`, 90 days max) as `TAILSCALE_API_KEY` for Terraform and `TS_API_KEY` for `rotate.py`. One user-owned key serves both because creating *share invites* needs a user-owned credential. OAuth clients are better for Terraform alone.
- A foundryvtt.com account with at least one license. **One key = one table open at a time**; four simultaneous tables need four keys. Check current terms at foundryvtt.com/article/license.
- Foundry systems are installed from Foundry's setup screen. The image tag is pinned to Foundry `13`; check each system's compatibility before moving to 14.

## 6. Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars      # fill in; git-ignored
export TAILSCALE_API_KEY=tskey-api-...
export TAILSCALE_TAILNET=-                        # "-" = key's default tailnet
cd .. && make init && make plan && make apply
```

`apply` creates, in order: ACL plus policy tests, one tagged auth key per node, VPC, security group (no inbound), IAM and SSM parameters, an encrypted data volume with daily snapshots, and an EC2 instance whose cloud-init installs Docker, Tailscale and the AWS CLI, mounts the volume, pulls secrets, joins the tailnet and starts the sidecars. On Windows, use PowerShell and `scripts\validate.ps1`.

```bash
make ssh                       # tailscale ssh ubuntu@tt-host (no keys, no port 22)
sudo tabletop status
sudo tabletop open pf2e        # needs a license key for that table
```

**First run of each table (manual, once):** open `https://tt-<table>.<tailnet>.ts.net`, accept the EULA, enter the admin key, then install the system under *Setup > Game Systems*:

| Table | System | How |
|---|---|---|
| `dnd` | Dungeons & Dragons Fifth Edition | search "dnd5e" |
| `daggerheart` | Foundryborne Daggerheart | search "Foundryborne", or manifest `https://raw.githubusercontent.com/Foundryborne/daggerheart/refs/heads/main/system.json` |
| `pf2e` | Pathfinder Second Edition | search in the installer |
| `sf2e` | Starfinder Second Edition | search in the installer |

Add players: put their emails in `roster.toml`, then `make rotate-apply`. They accept the emailed invite from their own Tailscale account and open the table URL. Tear down with `make destroy` (the data volume has `prevent_destroy`).

## 7. Validate

`make validate` (or `scripts\validate.ps1`) writes `docs/evidence/validation-<timestamp>.txt`. It checks:

1. All five nodes are online with their tags.
2. `tailscale ping tt-host` answers, showing a direct path or DERP region.
3. Each table's `/api/status` returns 200 over HTTPS (SKIP if the table is closed).
4. Public ports 22, 80, 443 and 30000 are closed, and the security group has 0 inbound rules.
5. `tailscale ssh ubuntu@tt-host` works with no keys.
6. A table cannot reach another table (isolation).
7. ACL `tests` run on every `terraform apply`; a failing test blocks the change.
8. A second account opens a shared table and reaches only that table.

Evidence checklist: [`docs/evidence/README.md`](docs/evidence/README.md).

## 8. Why Tailscale vs. the traditional options

| Approach | What it takes | Where it hurts here |
|---|---|---|
| Public IP + reverse proxy | Open 443, certs, rate limiting, auth in front of Foundry | Foundry's login is a shared-ish world password, and every scanner can reach it |
| Bastion host | Open 22, manage keys, tunnel each app | Per-person keys to rotate; players aren't engineers; no per-app scoping |
| Traditional VPN | Run a gateway, issue configs, set up routes and DNS | A listening port, hand-managed peers, all-or-nothing access, someone on call |
| Security-group allow-lists | Collect each player's IP | Home IPs change; travel and mobile break; manual edits |
| **Tailscale (this repo)** | Install the client; share a node | Identity-based, no inbound ports, per-app ACLs as code, per-person sharing, direct paths with encrypted relay fallback |

To someone new: *"Your service has no public address at all. People reach it through an encrypted private path that exists only for the person and service you chose, and you can see and change that list in a file."*

## 9. Cost (estimates; verify before committing)

Check the AWS pricing calculator. `t4g.small` is cheap but not free-tier-exempt for long, plus roughly $4 to $5 a month for about 46 GB of gp3 and a little for snapshots. Stopping the instance between sessions leaves only storage. Tailscale and the sidecars are free, and Foundry licenses are one-time purchases.

## 10. Honest status

Deployed to a real AWS account and tailnet, and validated on 2026-11-20 (`docs/evidence/`): **13 passed, 1 failed, 3 skipped.**

| Result | Detail |
|---|---|
| Proven | Five nodes online and tagged; Pathfinder 2e table live over HTTPS (Foundry 13.351); no public ports and 0 inbound rules; Tailscale SSH; table-to-table isolation (`no matching peer`); a friend on their own Tailscale account reached the shared table |
| The 1 failure | A bug in `validate.ps1`: it marks `tailscale ping` as failed when pongs arrive only via a DERP relay. The network worked |
| The 3 skips | `dnd`, `daggerheart` and `sf2e` are intentionally closed (HTTP 502) |
| Not verified | `rotate.py` against the live Tailscale API (only a mock); that accepted shares can't be revoked by API (from third-party docs); the other three tables never set up; why the path was relayed (DERP) rather than direct |

## 11. Reflection

**What worked well:**
- Connecting Tailscale, AWS and Foundry VTT so nothing of value is exposed to the internet, with no inbound rules to manage.
- Most of the setup is code: Terraform for ACL, keys and cloud, and one CLI to open and close tables.
- Tailscale was the "easy part". It provides the focal function a **Game Master** needs for the tables.

**What was difficult or surprising:**
- Foundry needs a separate license per table to run tables simultaneously. Each is a one-time purchase that a professional **Game Master** could easily afford.
- Revoking accepted Tailscale shares is manual, not available in the API.
- AWS permissions and node access were the bigger challenge. I would suggest a platform like DigitalOcean for future deployments.

**What I would do differently with more time:**
- Use a private subnet with VPC endpoints instead of a public IP with no inbound rules (the AI's suggestion).
- Pre-seed Foundry systems and modules from a manifest, and perhaps use multiple licenses, to fully automate tables.
- Replace the user API key with an OAuth client or workload identity federation for Terraform and CI, keeping the user key only for share invites. This needs live testing with players to confirm the experience is easy.
- Add webhooks that alert when a new node or share appears.
- Build a Tailscale Kubernetes variant for comparison.

## 12. AI assistance disclosure

AI was heavily used. I have very limited direct experience with these tools beyond understanding what they do and how they're typically used. I know how an internal combustion engine works, but I could not build or fix one.

- **Claude (Anthropic)** researched Tailscale sharing, API and ACLs, and drafted the Terraform, cloud-init and bootstrap, compose file, `rotate.py`, validation scripts, CI workflow and much of this README.
- **The AI checked itself** with compose rendering, shell, JSON, TOML and YAML syntax, and `rotate.py` against a mock API.
- **I reviewed and changed:** the AWS region (free account limits); Foundry license and sharing capabilities; and added 1Password for credential security.
- **The AI was wrong or incomplete:**
  - The first draft put sensitive values where Terraform rejected them; it was changed to iterate over key names.
  - Despite being told I was on Windows in Ontario, I had to ask for PowerShell instructions and corrected region settings more than once.
  - It repeatedly suggested `t4g.medium`; I corrected it to `t4g.small` after confirming my account's limits three times.
  - Several instructions were incomplete. For example, the Tailscale API token was not drawn from the 1Password CLI and I had to apply it directly.
  - It guessed the Foundry container user ID wrong (421, actually 1000), which caused a permissions error.

## 13. Repository layout

```
terraform/   AWS + Tailscale (ACL with tests, tagged keys, VPC, IAM, SSM, EBS, DLM, EC2)
host/        docker-compose (4 sidecars + 4 Foundry), serve.json, bootstrap.sh, tabletop CLI
access/      roster.toml and rotate.py (share reconciliation + seat audit)
scripts/     validate.sh, validate.ps1
docs/        architecture.md, evidence/
.github/     access-rotation workflow
Makefile     init/plan/apply/validate/rotate-plan/rotate-apply/seats/ssh/check
```
