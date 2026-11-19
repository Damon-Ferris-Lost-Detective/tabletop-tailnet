# Validation evidence

`scripts/validate.sh` writes a timestamped `validation-*.txt` file in this folder every time it runs.
Commit the output of a real run before submitting. Capture these by hand too:

| # | What to capture | Command / place | Proves |
|---|---|---|---|
| 1 | Nodes online with tags | `tailscale status` and the admin console Machines page (screenshot) | Five nodes, each owned by a tag |
| 2 | Direct vs relayed path | `tailscale ping tt-host` (look for `via <ip:port>` vs `via DERP(...)`) | How traffic actually flows |
| 3 | HTTPS to a table | `curl -sS https://tt-pf2e.<tailnet>.ts.net/api/status` | Valid cert, Foundry reachable over the tailnet |
| 4 | No public exposure | `nc -zv -w3 <public_ip> 22 80 443 30000` and `aws ec2 describe-security-groups` | Zero inbound surface |
| 5 | Policy tests | `terraform apply` output (tests pass) or the admin console Access controls > Tests | ACL intent is machine-checked |
| 6 | Tables are isolated | `validate.sh` section 6 | Compromise of one table does not spread |
| 7 | Rotation | `make rotate-plan` before and after editing `roster.toml`; a second account accepting a share and opening the table (screenshot) | A non-seat user can be added and removed |
| 8 | Seat audit | `make seats` | Member seats <= 6 |
| 9 | Foundry in the browser | Screenshot of each system's world list (dnd5e, Daggerheart, pf2e, sf2e) | All four tabletops run |

## Run log

_Fill in after the real deployment._

| Date | What I ran | Result | File |
|---|---|---|---|
| | | | |
