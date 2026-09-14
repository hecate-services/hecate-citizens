#!/usr/bin/env bash
# Window 2 checks for hecate-citizens 793f16d, run once both instances are on
# the new image. Mesh writes approved by Raf with the rollout. Each uses a
# scratch identity made here, never the default macula-cli identity, and a
# 2-minute TTL, so nothing it leaves outlives the check. The seeds are deleted
# at the end and never printed; ids are shown as 12-char prefixes.
#
#  1. A presence fact from an unlisted publisher is refused: one well-formed
#     hecate_citizens.citizen_presence fact from scratch identity A, shaped like
#     register_presence_responder:presence_fact/1, through the list station.
#     A's did must not appear in list_citizens.
#  2. A real registration federates: scratch identity B registers itself
#     through the register station (the other instance's). B's did must appear
#     in list_citizens through the list station, answered by the listing
#     instance.
#  3. Meanwhile an Erlang subscriber records each citizen_presence fact's
#     publisher and publisher_verified (citizens_presence_publisher_probe.sh).
#
# usage: citizens_window2_probes.sh <list station host:port> <register station host:port> <realm hex> <out dir>
set -uo pipefail

LIST_STATION=$1
REGISTER_STATION=$2
REALM=$3
OUT=$4
SP="${SP:-/tmp/claude-1000/-home-rl-work-github-com/27814434-b7e8-4c42-a13a-47261e4ed66a/scratchpad}"
CLI=${MACULA_CLI:-/home/rl/.local/bin/macula-cli}
TTL_MS=120000

mkdir -p "$OUT" "$SP/probe-identities"
ID_A="$SP/probe-identities/window2-forged.seed"
ID_B="$SP/probe-identities/window2-registration.seed"
cleanup() { /usr/bin/rm -f "$ID_A" "$ID_B"; }
trap cleanup EXIT

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"][sys.argv[2]])' "$1" "$2"; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# One list_citizens call through the list station: which instance answered,
# and whether <did> is listed.
listed() {
  local f="$OUT/list-$2.json"
  "$CLI" call -json -timeout 15s -realm "$REALM" "$LIST_STATION" hecate_citizens.list_citizens > "$f" 2>&1
  python3 - "$f" "$1" <<'PY'
import json, sys, time
path, did = sys.argv[1], sys.argv[2]
try:
    reply = json.load(open(path))
except Exception:
    print("  call failed: unreadable reply"); sys.exit(0)
if not reply.get("ok"):
    print(f"  call failed: {json.dumps(reply.get('error'))[:160]}"); sys.exit(0)
data = reply.get("data") or {}
responder = (data.get("responded_by") or "?")[:12]
entries = [c for c in (data.get("payload") or {}).get("citizens", []) if c.get("citizen_did") == did]
if entries:
    left = int((entries[0].get("expires_at", 0) - time.time() * 1000) / 1000)
    print(f"  responder {responder}: {did[:12]} LISTED, name={entries[0].get('display_name')!r}, expires_in={left}s")
else:
    print(f"  responder {responder}: {did[:12]} not listed")
PY
}

"$CLI" identity -json -identity "$ID_A" > "$OUT/identity-a.json" || exit 2
"$CLI" identity -json -identity "$ID_B" > "$OUT/identity-b.json" || exit 2
DID_A=$(field "$OUT/identity-a.json" node_id)
DID_B=$(field "$OUT/identity-b.json" node_id)
echo "scratch identities: forged publisher A ${DID_A:0:12}, registering citizen B ${DID_B:0:12}"

echo "### subscriber on citizen_presence for 100 s"
"$SP/citizens_presence_publisher_probe.sh" "$SP/fix-hecate-citizens" "$REALM" 100 "https://$LIST_STATION" > "$OUT/subscriber.log" 2>&1 &
SUB=$!
sleep 8

echo "### 1. forged fact from A through $LIST_STATION"
NOW=$(now_ms)
python3 - "$DID_A" "$NOW" "$TTL_MS" > "$OUT/forged-payload.json" <<'PY'
import json, sys
did, now, ttl = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
print(json.dumps({"citizen_did": did, "citizen_kind": "agent",
                  "display_name": "saturnus-window2-forged-probe",
                  "offers": ["conversation"], "registered_at": now,
                  "expires_at": now + ttl, "ttl_ms": ttl}))
PY
"$CLI" pubsub publish -json -realm "$REALM" -identity "$ID_A" -payload "$(cat "$OUT/forged-payload.json")" \
  "$LIST_STATION" hecate_citizens.citizen_presence > "$OUT/forged-publish.json" 2>&1
python3 - "$OUT/forged-publish.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("  publish: " + ("ok" if d.get("ok") else json.dumps(d.get("error"))[:160]))
except Exception:
    print("  publish: unreadable reply: " + open(sys.argv[1]).read()[:200])
PY
sleep 15
for i in 1 2 3; do listed "$DID_A" "forged-$i"; done

echo "### 2. registration of B through $REGISTER_STATION"
"$CLI" identity sign -json -identity "$ID_B" -procedure hecate_citizens.register_presence > "$OUT/proof-b.json" || exit 3
python3 - "$DID_B" "$(field "$OUT/proof-b.json" timestamp)" "$(field "$OUT/proof-b.json" signature)" "$TTL_MS" \
  > "$OUT/registration-payload.json" <<'PY'
import json, sys
did, ts, sig, ttl = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
print(json.dumps({"citizen_did": did, "citizen_kind": "agent",
                  "display_name": "saturnus-window2-registration-probe",
                  "offers": ["conversation"], "ttl_ms": ttl,
                  "proof": {"timestamp": ts, "signature": sig}}))
PY
"$CLI" call -json -timeout 15s -realm "$REALM" -identity "$ID_B" -args "$(cat "$OUT/registration-payload.json")" \
  "$REGISTER_STATION" hecate_citizens.register_presence > "$OUT/registration.json" 2>&1
python3 - "$OUT/registration.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("  register: unreadable reply"); sys.exit(0)
data = d.get("data") or {}
print(f"  register: ok={d.get('ok')} responder={(data.get('responded_by') or '?')[:12]} "
      f"payload={json.dumps(data.get('payload'))[:160]} error={json.dumps(d.get('error'))[:160]}")
PY
for i in 1 2 3 4 5 6; do sleep 5; listed "$DID_B" "registration-$i"; done

echo "### 3. subscriber (A is ${DID_A:0:12})"
wait "$SUB"
python3 - "$OUT/subscriber.log" <<'PY'
import collections, sys
counts = collections.Counter()
for line in open(sys.argv[1]):
    if "publisher=" in line:
        parts = dict(p.split("=", 1) for p in line.split() if "=" in p)
        counts[(parts.get("publisher", "?")[:12], parts.get("verified"))] += 1
    elif line.startswith("===") or "error" in line.lower():
        print("  " + line.strip()[:200])
for (publisher, verified), n in sorted(counts.items()):
    print(f"  publisher {publisher} verified={verified}: {n} facts")
PY
