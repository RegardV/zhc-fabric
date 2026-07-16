#!/usr/bin/env bash
# Setup zhc-fabric inference config.
#   setup.sh              interactive menu (wizard or manual)
#   setup.sh --wizard     prompt for URL / model / key, write env, start sidecar
#   setup.sh --manual     skip prompts; print what to edit and where
#   setup.sh --help
set -euo pipefail

ROOT="${ZHC_FABRIC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${HERMES_HOME:-$HOME/.hermes}/zhc-fabric"
ENV_FILE="$STATE_DIR/sidecar.env"
HERMES_ENV="${HERMES_HOME:-$HOME/.hermes}/.env"
EXAMPLE="$ROOT/sidecar.env.example"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

usage() {
  cat <<EOF
usage: $0 [--wizard|--manual|--help]

  --wizard   Interactive prompts for base URL, model id, optional API key;
             writes $ENV_FILE and starts the sidecar.
  --manual   Skip prompts. Print exact files/vars to edit, drop a template
             if none exists, then exit (you start the sidecar yourself).
  (no args)  Ask which path you want (TTY), or --manual if not a TTY.

Examples:
  $0 --wizard
  $0 --manual
  # then edit and:
  $ROOT/scripts/install-sidecar.sh start
EOF
}

print_manual() {
  cat <<EOF
=== zhc-fabric — manual config (no prompts) ===

Skip the interactive wizard and set the model endpoint yourself.

────────────────────────────────────────────────────────────
FILE 1 (preferred for fabric) — sidecar env
────────────────────────────────────────────────────────────
  Path:  $ENV_FILE
  Mode:  chmod 600 $ENV_FILE

  Create/edit with your editor, for example:
    mkdir -p $STATE_DIR
    cp $EXAMPLE $ENV_FILE
    nano $ENV_FILE    # or vim / code / …
    chmod 600 $ENV_FILE

  Set at least:
    ZHC_FABRIC_DEFAULT_BASE_URL=…   # e.g. http://127.0.0.1:11434/v1
    ZHC_FABRIC_DEFAULT_MODEL=…      # e.g. llama3.2
    ZHC_FABRIC_DEFAULT_API_KEY=…    # optional; leave empty for local

  Same meaning under classic names (also work):
    DEFAULT_BASE_URL / DEFAULT_MODEL / DEFAULT_API_KEY

────────────────────────────────────────────────────────────
FILE 2 (optional) — Hermes global .env
────────────────────────────────────────────────────────────
  Path:  $HERMES_ENV
  Hint:  hermes config env-path

  You can put the same ZHC_FABRIC_DEFAULT_* lines there instead of (or
  in addition to) sidecar.env. Do not commit this file.

────────────────────────────────────────────────────────────
Examples
────────────────────────────────────────────────────────────
  Ollama local:
    ZHC_FABRIC_DEFAULT_BASE_URL=http://127.0.0.1:11434/v1
    ZHC_FABRIC_DEFAULT_MODEL=llama3.2
    ZHC_FABRIC_DEFAULT_API_KEY=

  llama.cpp:
    ZHC_FABRIC_DEFAULT_BASE_URL=http://127.0.0.1:8000/v1
    ZHC_FABRIC_DEFAULT_MODEL=<your-model-id>
    ZHC_FABRIC_DEFAULT_API_KEY=

  OpenRouter (needs key):
    ZHC_FABRIC_DEFAULT_BASE_URL=https://openrouter.ai/api/v1
    ZHC_FABRIC_DEFAULT_MODEL=openai/gpt-4o-mini
    ZHC_FABRIC_DEFAULT_API_KEY=sk-or-…

────────────────────────────────────────────────────────────
After editing
────────────────────────────────────────────────────────────
  $ROOT/scripts/install-sidecar.sh start
  $ROOT/scripts/smoke.sh
  hermes gateway restart    # if Hermes was already running
  # In chat: /fabric status

Re-run interactive setup anytime:
  $0 --wizard
EOF

  if [[ ! -f "$ENV_FILE" && -f "$EXAMPLE" ]]; then
    cp "$EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo
    echo "Created template (edit me): $ENV_FILE"
  elif [[ -f "$ENV_FILE" ]]; then
    echo
    echo "Existing config left untouched: $ENV_FILE"
  fi
}

run_wizard() {
  # shellcheck disable=SC1091
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  cur_url="${ZHC_FABRIC_DEFAULT_BASE_URL:-${DEFAULT_BASE_URL:-}}"
  cur_model="${ZHC_FABRIC_DEFAULT_MODEL:-${DEFAULT_MODEL:-}}"
  cur_key="${ZHC_FABRIC_DEFAULT_API_KEY:-${DEFAULT_API_KEY:-}}"
  cur_inflight="${MAX_INFLIGHT_COMPLETIONS:-2}"

  echo "=== zhc-fabric setup (interactive) ==="
  echo "Will write: $ENV_FILE"
  echo "Tip: Ctrl+C and run: $0 --manual   to edit files yourself."
  echo "Examples:"
  echo "  Ollama:     http://127.0.0.1:11434/v1   model=llama3.2"
  echo "  llama.cpp:  http://127.0.0.1:8000/v1    model=<your-model-id>"
  echo "  OpenRouter: https://openrouter.ai/api/v1 + API key"
  echo

  prompt() {
    local label="$1" default="$2" secret="${3:-0}" value=""
    if [[ -n "$default" && "$secret" != "1" ]]; then
      printf "%s [%s]: " "$label" "$default"
    elif [[ -n "$default" && "$secret" == "1" ]]; then
      printf "%s [set — Enter keep, '-' clear]: " "$label"
    else
      printf "%s: " "$label"
    fi
    if [[ "$secret" == "1" ]]; then
      # shellcheck disable=SC2162
      read -r -s value || true
      echo
    else
      # shellcheck disable=SC2162
      read -r value || true
    fi
    if [[ -z "$value" ]]; then
      printf '%s' "$default"
      return
    fi
    if [[ "$secret" == "1" && "$value" == "-" ]]; then
      printf ''
      return
    fi
    printf '%s' "$value"
  }

  local new_url new_model new_key new_inflight
  new_url="$(prompt "Base URL (…/v1)" "$cur_url")"
  new_model="$(prompt "Model id" "$cur_model")"
  new_key="$(prompt "API key (optional)" "$cur_key" 1)"
  new_inflight="$(prompt "Max concurrent LLM calls" "$cur_inflight")"

  if [[ -z "$new_url" || -z "$new_model" ]]; then
    echo "error: base URL and model id are required." >&2
    echo "Or skip prompts: $0 --manual" >&2
    exit 1
  fi
  new_url="${new_url%/}"

  umask 077
  cat >"$ENV_FILE" <<EOF
# Generated by scripts/setup.sh --wizard — do not commit.
ZHC_FABRIC_DEFAULT_BASE_URL=$new_url
ZHC_FABRIC_DEFAULT_MODEL=$new_model
ZHC_FABRIC_DEFAULT_API_KEY=$new_key
DEFAULT_BASE_URL=$new_url
DEFAULT_MODEL=$new_model
DEFAULT_API_KEY=$new_key
MAX_INFLIGHT_COMPLETIONS=$new_inflight
EOF
  chmod 600 "$ENV_FILE"

  cat >"$STATE_DIR/config.json" <<EOF
{
  "url": "http://127.0.0.1:7733",
  "default_base_url": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$new_url"),
  "default_model": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$new_model"),
  "has_api_key": $([[ -n "$new_key" ]] && echo true || echo false)
}
EOF
  chmod 600 "$STATE_DIR/config.json" 2>/dev/null || true

  echo
  echo "Wrote $ENV_FILE"
  echo "  base_url=$new_url"
  echo "  model=$new_model"
  echo "  api_key=$([[ -n "$new_key" ]] && echo '(set)' || echo '(empty)')"
  echo

  if [[ -d "${HERMES_HOME:-$HOME/.hermes}" ]]; then
    python3 - <<PY
from pathlib import Path
import os, re
env_path = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")) / ".env"
pairs = {
    "ZHC_FABRIC_DEFAULT_BASE_URL": """${new_url}""",
    "ZHC_FABRIC_DEFAULT_MODEL": """${new_model}""",
    "ZHC_FABRIC_DEFAULT_API_KEY": """${new_key}""",
}
text = env_path.read_text(encoding="utf-8") if env_path.is_file() else ""
for k, v in pairs.items():
    line = f"{k}={v}"
    pat = re.compile(rf"(?m)^{re.escape(k)}=.*$")
    if pat.search(text):
        text = pat.sub(line, text)
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text += line + "\n"
env_path.parent.mkdir(parents=True, exist_ok=True)
env_path.write_text(text, encoding="utf-8")
try:
    env_path.chmod(0o600)
except OSError:
    pass
print(f"Synced ZHC_FABRIC_DEFAULT_* into {env_path}")
PY
  fi

  echo "Starting sidecar..."
  bash "$ROOT/scripts/install-sidecar.sh" restart
  echo
  echo "Done. In Hermes: /fabric status"
  echo "Smoke: $ROOT/scripts/smoke.sh"
}

choose_mode() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    print_manual
    return
  fi
  echo "=== zhc-fabric setup ==="
  echo "1) Interactive — enter URL, model, optional API key now"
  echo "2) Manual      — skip prompts; show what to edit and where"
  echo
  local ans=""
  # shellcheck disable=SC2162
  read -r -p "Choice [1/2, default 1]: " ans || true
  case "${ans:-1}" in
    2|m|M|manual) print_manual ;;
    *) run_wizard ;;
  esac
}

case "${1:-}" in
  -h|--help|help) usage ;;
  --manual|-m|manual) print_manual ;;
  --wizard|-w|wizard) run_wizard ;;
  "") choose_mode ;;
  *)
    echo "unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac
