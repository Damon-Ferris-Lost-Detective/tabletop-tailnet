#!/usr/bin/env python3
"""Reconcile per-table device shares with access/roster.toml.

Why this exists: the free Tailscale plan allows 6 users per tailnet. Players who
are *invited into* the tailnet each use a seat; players who are *shared a device*
do not. So the roster is enforced with device shares, and this tool also audits
the seat count so you notice before you hit the cap.

Commands
  plan    show what would change (default; changes nothing)
  apply   create missing share invites, delete stale *pending* invites
  seats   count tailnet members against the free-plan limit

Credentials: TS_API_KEY (a user-owned tskey-api-... key). Creating a share
invite records who sent it, so an OAuth client credential cannot do it.

Limitation (checked against the public API docs, not against a live tailnet):
the API can create/list/delete invites, but deleting an invite does not remove a
share that was already accepted. Accepted-but-not-on-roster players are reported
as REVOKE MANUALLY (admin console > Machines > <node> > Share). Verify this
against https://tailscale.com/api before relying on it.

Python 3.11+, standard library only.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

API = os.environ.get("TS_API_BASE", "https://api.tailscale.com/api/v2").rstrip("/")
FREE_SEAT_LIMIT = 6
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class ApiError(RuntimeError):
    pass


def call(method: str, path: str, body=None):
    key = os.environ.get("TS_API_KEY")
    if not key:
        sys.exit("TS_API_KEY is not set (create one at https://login.tailscale.com/admin/settings/keys)")
    token = base64.b64encode(f"{key}:".encode()).decode()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Authorization", f"Basic {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise ApiError(f"{method} {path} -> HTTP {e.code}: {e.read().decode(errors='replace')[:300]}") from None
    except urllib.error.URLError as e:
        raise ApiError(f"{method} {path} -> {e.reason}") from None
    return json.loads(raw) if raw.strip() else {}


def load_roster(path: Path) -> dict:
    with path.open("rb") as f:
        roster = tomllib.load(f)
    tables = roster.get("tables") or {}
    if not tables:
        sys.exit(f"{path}: no [tables.*] defined")
    for name, t in tables.items():
        if "node" not in t:
            sys.exit(f"{path}: [tables.{name}] needs a 'node'")
        t["players"] = sorted({p.strip().lower() for p in t.get("players", [])})
        for p in t["players"]:
            if not EMAIL_RE.match(p):
                sys.exit(f"{path}: [tables.{name}] has an invalid email: {p!r}")
    roster.setdefault("tailnet", "-")
    return roster


def find_device(tailnet: str, node: str) -> dict | None:
    devices = call("GET", f"/tailnet/{tailnet}/devices").get("devices", [])
    hits = [d for d in devices if d.get("hostname") == node or d.get("name", "").split(".")[0] == node]
    if len(hits) > 1:
        print(f"  ! {len(hits)} devices match {node!r}; using the first. Delete stale duplicates in the console.", file=sys.stderr)
    return hits[0] if hits else None


def device_id(d: dict) -> str:
    return d.get("nodeId") or d["id"]


def list_invites(dev_id: str) -> list[dict]:
    res = call("GET", f"/device/{dev_id}/device-invites")
    return res.get("invites", []) if isinstance(res, dict) else res


def classify(invites: list[dict]):
    pending, accepted = {}, {}
    for inv in invites:
        if inv.get("accepted"):
            who = (inv.get("acceptedBy") or {}).get("loginName") or inv.get("email") or ""
            accepted[who.lower()] = inv
        elif inv.get("email"):
            pending[inv["email"].lower()] = inv
    return pending, accepted


def reconcile(roster: dict) -> list[dict]:
    """Return one work item per table describing the gap between roster and reality."""
    work = []
    for name, t in roster["tables"].items():
        item = {"table": name, "node": t["node"], "device": None,
                "invite": [], "delete_pending": [], "revoke_manually": [], "ok": []}
        dev = find_device(roster["tailnet"], t["node"])
        if dev is None:
            item["error"] = f"node {t['node']!r} is not in the tailnet yet (is the host up?)"
            work.append(item)
            continue
        item["device"] = device_id(dev)
        pending, accepted = classify(list_invites(item["device"]))
        want = set(t["players"])
        item["ok"] = sorted(want & (set(pending) | set(accepted)))
        item["invite"] = sorted(want - set(pending) - set(accepted))
        item["delete_pending"] = [(e, pending[e]["id"]) for e in sorted(set(pending) - want)]
        item["revoke_manually"] = sorted(set(accepted) - want)
        work.append(item)
    return work


def show(work: list[dict]) -> tuple[bool, bool]:
    """Print the plan. Returns (actionable, needs_attention).

    actionable      = apply can fix it (INVITE / CANCEL)
    needs_attention = something a human must do (REVOKE MANUALLY, missing node)
    """
    actionable = attention = False
    for w in work:
        print(f"\n[{w['table']}]  node={w['node']}")
        if w.get("error"):
            print(f"  ERROR  {w['error']}")
            attention = True
            continue
        for e in w["ok"]:
            print(f"  ok       {e}")
        for e in w["invite"]:
            print(f"  INVITE   {e}")
            actionable = True
        for e, _ in w["delete_pending"]:
            print(f"  CANCEL   {e}   (pending invite, no longer on roster)")
            actionable = True
        for e in w["revoke_manually"]:
            print(f"  REVOKE MANUALLY  {e}   (already accepted; remove in admin console > Machines > {w['node']} > Share)")
            attention = True
    return actionable, attention


def apply(work: list[dict]) -> int:
    failures = 0
    for w in work:
        if w.get("error"):
            failures += 1
            continue
        if w["invite"]:
            body = [{"email": e, "multiUse": False, "allowExitNode": False} for e in w["invite"]]
            try:
                call("POST", f"/device/{w['device']}/device-invites", body)
                print(f"  [{w['table']}] invited {', '.join(w['invite'])}")
            except ApiError as e:
                print(f"  [{w['table']}] invite failed: {e}", file=sys.stderr)
                failures += 1
        for email, inv_id in w["delete_pending"]:
            try:
                call("DELETE", f"/device-invites/{inv_id}")
                print(f"  [{w['table']}] cancelled pending invite for {email}")
            except ApiError as e:
                print(f"  [{w['table']}] cancel failed: {e}", file=sys.stderr)
                failures += 1
    return failures


def seats(roster: dict) -> int:
    users = call("GET", f"/tailnet/{roster['tailnet']}/users").get("users", [])
    members = [u for u in users if u.get("type", "member") != "shared" and u.get("status") != "suspended"]
    print(f"Tailnet members using a seat: {len(members)} / {FREE_SEAT_LIMIT}")
    for u in members:
        print(f"  - {u.get('loginName') or u.get('displayName')}  role={u.get('role')}  status={u.get('status')}")
    if len(members) > FREE_SEAT_LIMIT:
        print("OVER the free-plan limit. Remove or suspend members, or share devices instead of inviting users.")
        return 1
    free = FREE_SEAT_LIMIT - len(members)
    print(f"{free} seat(s) free. Players added via the roster do not use seats.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", nargs="?", default="plan", choices=["plan", "apply", "seats"])
    ap.add_argument("--roster", type=Path, default=Path(__file__).with_name("roster.toml"))
    ap.add_argument("--yes", action="store_true", help="apply without prompting (CI)")
    ap.add_argument("--check", action="store_true", help="plan: exit 2 if anything needs to change")
    args = ap.parse_args()

    roster = load_roster(args.roster)
    try:
        if args.command == "seats":
            return seats(roster)
        work = reconcile(roster)
        actionable, attention = show(work)
        if args.command == "plan":
            if actionable:
                print("\nChanges needed. Run: make rotate-apply")
            elif attention:
                print("\nNothing for apply to do, but items above need a human.")
            else:
                print("\nNo changes needed.")
            return 2 if ((actionable or attention) and args.check) else 0
        if not actionable:
            print("\nNothing to apply." + (" (Items above need a human.)" if attention else ""))
            return 0
        if not args.yes and input("\nApply the INVITE / CANCEL changes above? [y/N] ").strip().lower() != "y":
            print("Aborted.")
            return 1
        print()
        return 1 if apply(work) else 0
    except ApiError as e:
        print(f"API error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
