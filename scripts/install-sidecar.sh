#!/usr/bin/env bash
# Start / stop / status for the zhc-fabric sidecar (Python stub MVP).
set -euo pipefail

ROOT="${ZHC_FABRIC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${HERMES_HOME:-$HOME/.hermes}/zhc-fabric"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/sidecar.pid"
LOG_FILE="$STATE_DIR/sidecar.log"
ENV_FILE="$STATE_DIR/sidecar.env"
HOST="${FABRIC_HOST:-127.0.0.1}"
PORT="${FABRIC_PORT:-7733}"
STUB="$ROOT/sidecar/stub/server.py"

# Load saved setup (setup.sh / install prompts)
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Fabric-prefixed names (from hermes plugins install → ~/.hermes/.env) win as fill-ins
export DEFAULT_BASE_URL="${DEFAULT_BASE_URL:-${ZHC_FABRIC_DEFAULT_BASE_URL:-}}"
export DEFAULT_MODEL="${DEFAULT_MODEL:-${ZHC_FABRIC_DEFAULT_MODEL:-}}"
export DEFAULT_API_KEY="${DEFAULT_API_KEY:-${ZHC_FABRIC_DEFAULT_API_KEY:-}}"
export MAX_INFLIGHT_COMPLETIONS="${MAX_INFLIGHT_COMPLETIONS:-2}"
export FABRIC_HOST="$HOST"
export FABRIC_PORT="$PORT"

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

health() {
  curl -fsS --max-time 2 "http://${HOST}:${PORT}/health" 2>/dev/null || return 1
}

require_inference_config() {
  if [[ -z "${DEFAULT_BASE_URL:-}" || -z "${DEFAULT_MODEL:-}" ]]; then
    echo "error: no inference endpoint configured for the fabric sidecar." >&2
    echo "  Run:  $ROOT/scripts/setup.sh" >&2
    echo "  Or set ZHC_FABRIC_DEFAULT_BASE_URL + ZHC_FABRIC_DEFAULT_MODEL" >&2
    echo "  (hermes plugins install prompts for these)." >&2
    return 1
  fi
}

cmd_start() {
  if is_running && health >/dev/null; then
    echo "zhc-fabric already running (pid $(cat "$PID_FILE")) on http://${HOST}:${PORT}"
    health | head -c 400; echo
    return 0
  fi
  # stale pid
  rm -f "$PID_FILE"

  if [[ ! -f "$STUB" ]]; then
    echo "error: stub server not found at $STUB" >&2
    return 1
  fi

  require_inference_config || return 1

  # Prefer docker if FABRIC_USE_DOCKER=1
  if [[ "${FABRIC_USE_DOCKER:-0}" == "1" ]] && command -v docker >/dev/null 2>&1; then
    echo "starting via docker compose..."
    (cd "$ROOT/sidecar" && docker compose up -d --build)
    sleep 1
    health && echo "ok (docker)" && return 0
    echo "docker start failed health check" >&2
    return 1
  fi

  nohup python3 "$STUB" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 0.4
  if health >/dev/null; then
    echo "zhc-fabric started pid=$(cat "$PID_FILE") http://${HOST}:${PORT}"
    echo "  DEFAULT_BASE_URL=$DEFAULT_BASE_URL"
    echo "  DEFAULT_MODEL=$DEFAULT_MODEL"
    echo "  api_key=$([[ -n "${DEFAULT_API_KEY:-}" ]] && echo set || echo empty)"
    echo "  log=$LOG_FILE"
    health; echo
    return 0
  fi
  echo "error: sidecar failed to become healthy; see $LOG_FILE" >&2
  tail -n 30 "$LOG_FILE" 2>/dev/null || true
  return 1
}

cmd_stop() {
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "stopped pid $pid"
  else
    echo "not running"
    rm -f "$PID_FILE"
  fi
  if [[ "${FABRIC_USE_DOCKER:-0}" == "1" ]] && command -v docker >/dev/null 2>&1; then
    (cd "$ROOT/sidecar" && docker compose down) || true
  fi
}

cmd_status() {
  if is_running; then
    echo "process: running pid=$(cat "$PID_FILE")"
  else
    echo "process: not running"
  fi
  echo "config: DEFAULT_BASE_URL=${DEFAULT_BASE_URL:-<unset>} DEFAULT_MODEL=${DEFAULT_MODEL:-<unset>}"
  if [[ -f "$ENV_FILE" ]]; then
    echo "env_file: $ENV_FILE"
  else
    echo "env_file: (none — run scripts/setup.sh)"
  fi
  if out="$(health)"; then
    echo "health: $out"
  else
    echo "health: unreachable at http://${HOST}:${PORT}"
    return 1
  fi
}

cmd_logs() {
  tail -n "${1:-50}" "$LOG_FILE" 2>/dev/null || echo "no log at $LOG_FILE"
}

usage() {
  echo "usage: $0 {start|stop|status|restart|logs}"
  echo "  first-time: $ROOT/scripts/setup.sh"
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  restart) cmd_stop || true; cmd_start ;;
  logs) cmd_logs "${2:-50}" ;;
  *) usage; exit 2 ;;
esac
