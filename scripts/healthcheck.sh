#!/usr/bin/env bash
set -euo pipefail
URL="${ZHC_FABRIC_URL:-http://127.0.0.1:7733}"
curl -fsS --max-time 3 "${URL%/}/health"
echo
