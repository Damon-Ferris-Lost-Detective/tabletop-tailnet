#!/usr/bin/env bash
# First-boot provisioning, run by cloud-init. Idempotent: safe to re-run by hand
# (sudo tabletop-sync is not needed; just run this script again).
set -euo pipefail
exec > >(tee -a /var/log/tabletop-bootstrap.log) 2>&1

# shellcheck disable=SC1091
. /etc/tabletop/bootstrap.env
log() { printf '\n==> %s\n' "$*"; }

# --- swap: a safety net on a 4 GiB box -------------------------------------
if ! swapon --show | grep -q .; then
  log "Creating 2G swap"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
timedatectl set-timezone "$TZ_NAME" || true

# --- persistent data volume -------------------------------------------------
log "Waiting for data volume $VOLUME_ID"
DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}"
for _ in $(seq 1 90); do [[ -e "$DEV" ]] && break; sleep 2; done
[[ -e "$DEV" ]] || { echo "Data volume never appeared"; exit 1; }
blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -L tabletop-data "$DEV"
mkdir -p /data
grep -q 'LABEL=tabletop-data' /etc/fstab || echo 'LABEL=tabletop-data /data ext4 defaults,nofail 0 2' >> /etc/fstab
mountpoint -q /data || mount /data

for t in $TABLES; do
  install -d -m 0755 -o 421 -g 421 "/data/foundry/$t"   # 421 = felddy image default user
  install -d -m 0700 "/data/tailscale/$t"
done

# --- software ---------------------------------------------------------------
command -v docker >/dev/null || { log "Installing Docker"; curl -fsSL https://get.docker.com | sh; }
command -v aws >/dev/null || {
  log "Installing AWS CLI v2 (arm64)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscli.zip
  unzip -q -o /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip
}
command -v tailscale >/dev/null || { log "Installing Tailscale"; curl -fsSL https://tailscale.com/install.sh | sh; }

# --- secrets: SSM -> /opt/tabletop/.env (root-only) -------------------------
# /<NAME>/license/dnd -> LICENSE_DND, /<NAME>/tskey/pf2e -> TSKEY_PF2E,
# /<NAME>/foundry/admin_key -> FOUNDRY_ADMIN_KEY, ...
log "Fetching secrets from SSM"
umask 077
aws ssm get-parameters-by-path --region "$REGION" --path "/$NAME/" --recursive --with-decryption --output json \
  | jq -r --arg p "/$NAME/" '.Parameters[]
      | "\((.Name | sub("^" + $p; "") | ascii_upcase | gsub("[/-]"; "_")))='"'"'\(.Value)'"'"'"' \
  > /opt/tabletop/.env.new
{ cat /opt/tabletop/.env.new
  echo "TAILNET_DOMAIN='$TAILNET_DOMAIN'"
  echo "TZ_NAME='$TZ_NAME'"
} > /opt/tabletop/.env
rm -f /opt/tabletop/.env.new
chmod 600 /opt/tabletop/.env
umask 022

# --- join the host to the tailnet (Tailscale SSH for administration) --------
HOST_KEY="$(sed -n "s/^TSKEY_HOST='\(.*\)'$/\1/p" /opt/tabletop/.env)"
if ! tailscale status >/dev/null 2>&1; then
  log "Joining tailnet as $HOST_NAME"
  tailscale up --authkey="$HOST_KEY" --hostname="$HOST_NAME" --ssh
fi

# --- start the always-on sidecars; Foundry containers are opened on demand --
log "Starting Tailscale sidecars"
cd /opt/tabletop
for t in $TABLES; do docker compose up -d "ts-$t"; done

cat <<EOF

Bootstrap finished. Nodes tt-* should appear in the Tailscale admin console.
Open a table (needs a license key for it):   sudo tabletop open pf2e
EOF
