#!/usr/bin/env bash
# Prove the environment behaves the way the README says it does.
# Run from YOUR machine, signed in to the tailnet as the admin, from the repo root:
#     scripts/validate.sh            # or: make validate
# Output is also saved to docs/evidence/validation-<timestamp>.txt
#
# Needs: tailscale, curl, jq, terraform (for the public IP). aws CLI is optional.
set -uo pipefail

TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
EVIDENCE_DIR="$(cd "$(dirname "$0")/../docs/evidence" && pwd)"
OUT="$EVIDENCE_DIR/validation-$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$OUT") 2>&1

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
skp()  { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; skip=$((skip+1)); }
hdr()  { printf '\n## %s\n' "$*"; }

tf() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }
DOMAIN="${TAILNET_DOMAIN:-$(terraform -chdir="$TF_DIR" console <<<'var.tailnet_domain' 2>/dev/null | tr -d '"')}"
PUBIP="$(tf public_ip)"
SG="$(tf security_group_id)"
TABLES=(dnd daggerheart pf2e sf2e)

echo "validation run: $(date -u +%FT%TZ)   tailnet: ${DOMAIN:-unknown}   host public ip: ${PUBIP:-unknown}"

# ---------------------------------------------------------------------------
hdr "1. Nodes are on the tailnet"
tailscale status --json | jq -r '.Peer[] | select(.HostName|startswith("tt-")) | "  \(.HostName)\t\(.TailscaleIPs[0])\tonline=\(.Online)\ttags=\(.Tags // [] | join(","))"'
for n in tt-host tt-dnd tt-daggerheart tt-pf2e tt-sf2e; do
  if tailscale status --json | jq -e --arg n "$n" '.Peer[] | select(.HostName==$n and .Online)' >/dev/null; then
    ok "$n is online"; else bad "$n is not online"; fi
done

# ---------------------------------------------------------------------------
hdr "2. Traffic path (direct vs. relayed) to the host"
tailscale ping --c 3 --timeout 5s tt-host && ok "tailscale ping tt-host answered" || bad "tailscale ping tt-host failed"

# ---------------------------------------------------------------------------
hdr "3. Open tables answer over tailnet HTTPS with a valid certificate"
for t in "${TABLES[@]}"; do
  url="https://tt-$t.$DOMAIN/api/status"
  code="$(curl -sS -o /tmp/fvtt-status.$$ -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    ok "$t  $url  -> 200  $(jq -c '{active,version,world}' /tmp/fvtt-status.$$ 2>/dev/null)"
  elif [[ "$code" == "502" || "$code" == "503" ]]; then
    skp "$t  node reachable but Foundry is closed (HTTP $code). Run: tailscale ssh ubuntu@tt-host sudo tabletop open $t"
  else
    bad "$t  $url  -> HTTP $code"
  fi
done
rm -f /tmp/fvtt-status.$$

# ---------------------------------------------------------------------------
hdr "4. Nothing is listening on the public internet"
if [[ -n "$PUBIP" ]]; then
  for port in 22 80 443 30000; do
    if timeout 4 bash -c ">/dev/tcp/$PUBIP/$port" 2>/dev/null; then bad "public $PUBIP:$port is OPEN"; else ok "public $PUBIP:$port is closed/filtered"; fi
  done
else
  skp "no public_ip from terraform output"
fi
if command -v aws >/dev/null && [[ -n "$SG" ]]; then
  n="$(aws ec2 describe-security-groups --group-ids "$SG" --query 'length(SecurityGroups[0].IpPermissions)' --output text 2>/dev/null)"
  [[ "$n" == "0" ]] && ok "security group $SG has 0 inbound rules" || bad "security group $SG has ${n:-?} inbound rules"
else
  skp "aws CLI not available; cannot read security group"
fi

# ---------------------------------------------------------------------------
hdr "5. Admin path: Tailscale SSH (no key, no open port 22)"
if out="$(tailscale ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@tt-host 'hostname; sudo tabletop status' 2>&1)"; then
  ok "tailscale ssh ubuntu@tt-host worked"; echo "$out" | sed 's/^/        /'
else
  bad "tailscale ssh failed: $out"
fi

# ---------------------------------------------------------------------------
hdr "6. Blast radius: a compromised table cannot reach another table"
src=dnd; dst=pf2e
dst_ip="$(tailscale ip -4 tt-$dst 2>/dev/null)"
if [[ -n "$dst_ip" ]]; then
  if tailscale ssh ubuntu@tt-host "sudo docker exec ts-$src tailscale ping --c 2 --timeout 5s $dst_ip" >/tmp/ping.$$ 2>&1; then
    bad "tt-$src reached tt-$dst ($dst_ip); the policy is too open"; cat /tmp/ping.$$
  else
    ok "tt-$src cannot reach tt-$dst ($dst_ip)"; sed 's/^/        /' /tmp/ping.$$ | head -3
  fi
  rm -f /tmp/ping.$$
else
  skp "could not resolve tt-$dst"
fi

# ---------------------------------------------------------------------------
printf '\n== %d passed, %d failed, %d skipped ==  (saved to %s)\n' "$pass" "$fail" "$skip" "$OUT"
[[ $fail -eq 0 ]]
