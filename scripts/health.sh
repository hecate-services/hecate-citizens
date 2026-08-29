#!/usr/bin/env bash
# Ask a running hecate-citizens how it is.
#
# Defaults to the local node on the port the image exposes. Pass a host to reach
# one on another host, for example:
#
#   scripts/health.sh a-remote-host
#   HECATE_HEALTH_PORT=8491 scripts/health.sh a-remote-host
#
# THREE OUTCOMES, NOT TWO, because they need different responses from whoever is
# reading. Unreachable means the container is not running or the port is wrong.
# Unhealthy means the node is up and telling you something is wrong with it, and
# hecate_om answers that with a 503 carrying a reason. Collapsing the two sends
# you to look in the wrong place.
#
#   0  healthy
#   1  reachable, reports degraded or down
#   2  unreachable

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${HECATE_HEALTH_PORT:-8491}"
URL="http://${HOST}:${PORT}/health"

# No -f, so a 503 arrives as a body to be shown rather than as a curl failure
# that hides the reason the service went to the trouble of reporting.
if ! RESPONSE="$(curl -sS --max-time 5 -w '\n%{http_code}' "${URL}" 2>/dev/null)"; then
    echo "unreachable: ${URL}" >&2
    exit 2
fi

CODE="${RESPONSE##*$'\n'}"
BODY="${RESPONSE%$'\n'*}"

# Pretty-print when python is around, otherwise show the raw body. A missing
# formatter must not turn a healthy node into a failed check.
if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${BODY}" | python3 -m json.tool 2>/dev/null || printf '%s\n' "${BODY}"
else
    printf '%s\n' "${BODY}"
fi

case "${CODE}" in
    200) exit 0 ;;
    "")  echo "no response from ${URL}" >&2 ; exit 2 ;;
    *)   echo "unhealthy (HTTP ${CODE}): ${URL}" >&2 ; exit 1 ;;
esac
