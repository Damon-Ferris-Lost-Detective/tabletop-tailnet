#!/usr/bin/env bash
# tabletop: open/close the Foundry tables on this host.
#   sudo tabletop status
#   sudo tabletop open  <table>
#   sudo tabletop close <table>
#   sudo tabletop logs  <table>
#
# Foundry's license allows ONE player-accessible instance per license key.
# `open` refuses to start a table whose license is already in use by a running one.
set -euo pipefail

# shellcheck disable=SC1091
. /etc/tabletop/bootstrap.env
ENV_FILE=/opt/tabletop/.env
cd /opt/tabletop

get() { sed -n "s/^$1='\(.*\)'$/\1/p" "$ENV_FILE" | head -1; }
upper() { echo "${1^^}"; }
license_of() { get "LICENSE_$(upper "$1")"; }
is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "foundry-$1" 2>/dev/null || true)" == "true" ]]; }
valid_table() { for t in $TABLES; do [[ "$t" == "$1" ]] && return 0; done; return 1; }
need_table() { valid_table "${1:-}" || { echo "Unknown table '${1:-}'. Choose one of: $TABLES"; exit 2; }; }

cmd="${1:-status}"
case "$cmd" in
  status)
    printf '%-12s %-9s %-9s %s\n' TABLE LICENSE FOUNDRY URL
    for t in $TABLES; do
      lic="none"; [[ -n "$(license_of "$t")" ]] && lic="set"
      st="closed"; is_running "$t" && st="open"
      printf '%-12s %-9s %-9s %s\n' "$t" "$lic" "$st" "https://tt-$t.$TAILNET_DOMAIN"
    done
    ;;
  open)
    t="${2:-}"; need_table "$t"
    mine="$(license_of "$t")"
    [[ -n "$mine" ]] || { echo "No license key stored for '$t'. Add it to foundry_license_keys and re-apply."; exit 1; }
    for o in $TABLES; do
      [[ "$o" == "$t" ]] && continue
      if is_running "$o" && [[ "$(license_of "$o")" == "$mine" ]]; then
        echo "Refusing: '$o' is open on the same license key. Run: tabletop close $o"
        exit 1
      fi
    done
    docker compose --profile "$t" up -d "foundry-$t"
    echo "Opened $t -> https://tt-$t.$TAILNET_DOMAIN"
    ;;
  close)
    t="${2:-}"; need_table "$t"
    docker compose stop "foundry-$t" || true
    echo "Closed $t (node tt-$t stays online so it remains shareable)."
    ;;
  logs)
    t="${2:-}"; need_table "$t"
    docker logs --tail 100 -f "foundry-$t"
    ;;
  *)
    echo "usage: tabletop {status|open <table>|close <table>|logs <table>}"; exit 2 ;;
esac
