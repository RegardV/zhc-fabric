#!/usr/bin/env bash
# End-to-end smoke: health + consensus against DEFAULT_BASE_URL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Prefer already-configured setup; only then fall back to common local defaults.
STATE_ENV="${HERMES_HOME:-$HOME/.hermes}/zhc-fabric/sidecar.env"
if [[ -f "$STATE_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$STATE_ENV"
  set +a
fi
export DEFAULT_BASE_URL="${DEFAULT_BASE_URL:-${ZHC_FABRIC_DEFAULT_BASE_URL:-}}"
export DEFAULT_MODEL="${DEFAULT_MODEL:-${ZHC_FABRIC_DEFAULT_MODEL:-}}"
export DEFAULT_API_KEY="${DEFAULT_API_KEY:-${ZHC_FABRIC_DEFAULT_API_KEY:-}}"
export ZHC_FABRIC_URL="${ZHC_FABRIC_URL:-http://127.0.0.1:7733}"
if [[ -z "$DEFAULT_BASE_URL" || -z "$DEFAULT_MODEL" ]]; then
  echo "error: no model URL/id configured. Run: $ROOT/scripts/setup.sh" >&2
  exit 1
fi

echo "== start sidecar =="
bash "$ROOT/scripts/install-sidecar.sh" start

echo "== health =="
bash "$ROOT/scripts/healthcheck.sh"

echo "== client offline-path unit (import) =="
python3 - <<'PY'
import sys
from pathlib import Path
root = Path(__file__).resolve().parent if False else Path(".")
# run from ROOT
sys.path.insert(0, str(Path.cwd()))
PY
cd "$ROOT"
python3 - <<'PY'
import json, sys
sys.path.insert(0, ".")
from client import FabricClient
from config import fabric_url

c = FabricClient(fabric_url(), timeout=5)
h = c.health()
print("health:", json.dumps(h, indent=2))
assert h.get("ok") is True, h

print("== consensus n=2 ==")
r = c.consensus(
    prompt="In one short sentence: what is 2+2? Reply with the number only if possible.",
    n=2,
    policy="majority",
    timeout_ms=90000,
)
print(json.dumps({k: r.get(k) for k in ("ok", "answer", "policy", "elapsed_ms", "error")}, indent=2))
print("votes:", len(r.get("votes") or []))
assert r.get("ok") is True, r
assert r.get("answer"), r
print("SMOKE OK")
PY
