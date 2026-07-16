#!/usr/bin/env bash
# Repo root has __init__.py (Hermes plugin contract), which breaks pytest
# collection from the root — so run from tests/.
set -euo pipefail
cd "$(dirname "$0")/../tests"
exec pytest -q --import-mode=importlib "$@" .
