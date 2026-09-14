#!/usr/bin/env bash
# Read-only: call hecate_citizens.list_citizens several times through a station
# with macula-cli, and report, per responding hecate-citizens instance, every
# live directory entry with its seconds until expiry. Flags any entry expiring
# later than the default 20-minute TTL plus the 60 s proof skew allows. A public
# procedure; macula-cli's own identity, no token. Raw replies go to OUT_DIR.
#
# usage: citizens_live_directory.sh <station host:port> <realm hex> <out dir> [calls]
set -uo pipefail

STATION=$1
REALM=$2
OUT_DIR=$3
CALLS=${4:-8}
CLI=${MACULA_CLI:-/home/rl/.local/bin/macula-cli}

mkdir -p "$OUT_DIR"
for i in $(seq 1 "$CALLS"); do
  "$CLI" call -json -timeout 15s -realm "$REALM" "$STATION" hecate_citizens.list_citizens \
    > "$OUT_DIR/list-$i.json" 2>&1
done

python3 - "$OUT_DIR" "$CALLS" <<'PY'
import glob
import json
import os
import sys

out_dir, calls = sys.argv[1], int(sys.argv[2])
limit_s = 20 * 60 + 60
by_responder = {}
failures = 0
for path in sorted(glob.glob(os.path.join(out_dir, "list-*.json"))):
    now_ms = os.path.getmtime(path) * 1000
    try:
        reply = json.load(open(path))
    except Exception:
        failures += 1
        continue
    if not reply.get("ok"):
        failures += 1
        continue
    data = reply.get("data") or {}
    responder = (data.get("responded_by") or data.get("respondedBy") or "?")[:12]
    payload = data.get("payload") or {}
    for c in payload.get("citizens", []):
        delta = int((c.get("expires_at", 0) - now_ms) / 1000)
        key = (c.get("citizen_did", "")[:12], c.get("citizen_kind"), c.get("display_name"),
               tuple(c.get("offers", [])))
        entry = by_responder.setdefault(responder, {})
        entry[key] = max(entry.get(key, delta), delta)

print(f"calls {calls}, failed {failures}, responders {len(by_responder)}")
for responder, entries in sorted(by_responder.items()):
    print(f"=== responder {responder}: {len(entries)} live entries")
    for (did, kind, name, offers), delta in sorted(entries.items(), key=lambda kv: -kv[1]):
        flag = "  BEYOND DEFAULT TTL" if delta > limit_s else ""
        print(f"  {did} kind={kind} name={name!r} offers={list(offers)} expires_in={delta}s{flag}")
PY
