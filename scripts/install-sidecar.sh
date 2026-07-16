#!/usr/bin/env bash
# Start / stop / status for the zhc-fabric sidecar.
#
# PRIMARY runtime: Docker image of the Erlang/OTP fabric (sidecar/otp).
#   You need Docker. You do NOT install Erlang on the host — it lives in the image.
# FALLBACK: Python stub only if FABRIC_RUNTIME=python (dev / no Docker).
set -euo pipefail

ROOT="${ZHC_FABRIC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${HERMES_HOME:-$HOME/.hermes}/zhc-fabric"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/sidecar.pid"
LOG_FILE="$STATE_DIR/sidecar.log"
ENV_FILE="$STATE_DIR/sidecar.env"
COMPOSE_FILE="$ROOT/sidecar/docker-compose.yml"
HOST="${FABRIC_HOST:-127.0.0.1}"
PORT="${FABRIC_PORT:-7733}"
STUB="$ROOT/sidecar/stub/server.py"
# otp (default) | python
RUNTIME="${FABRIC_RUNTIME:-otp}"
CONTAINER_NAME="${FABRIC_CONTAINER_NAME:-zhc-fabric}"

# Load saved setup (setup.sh)
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

export DEFAULT_BASE_URL="${DEFAULT_BASE_URL:-${ZHC_FABRIC_DEFAULT_BASE_URL:-}}"
export DEFAULT_MODEL="${DEFAULT_MODEL:-${ZHC_FABRIC_DEFAULT_MODEL:-}}"
export DEFAULT_API_KEY="${DEFAULT_API_KEY:-${ZHC_FABRIC_DEFAULT_API_KEY:-}}"
export MAX_INFLIGHT_COMPLETIONS="${MAX_INFLIGHT_COMPLETIONS:-2}"
export FABRIC_HOST="$HOST"
export FABRIC_PORT="$PORT"
export ZHC_FABRIC_DEFAULT_BASE_URL="${ZHC_FABRIC_DEFAULT_BASE_URL:-$DEFAULT_BASE_URL}"
export ZHC_FABRIC_DEFAULT_MODEL="${ZHC_FABRIC_DEFAULT_MODEL:-$DEFAULT_MODEL}"
export ZHC_FABRIC_DEFAULT_API_KEY="${ZHC_FABRIC_DEFAULT_API_KEY:-$DEFAULT_API_KEY}"

is_python_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

is_docker_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

health() {
  curl -fsS --max-time 2 "http://${HOST}:${PORT}/health" 2>/dev/null || return 1
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<EOF
error: Docker is required for the zhc-fabric OTP sidecar (the main runtime).

  Install Docker Engine or Docker Desktop, then re-run:
    $0 start

  You do NOT need to install Erlang/OTP on this machine — the container
  image already includes Erlang 27 and builds the fabric inside Docker.

  Escape hatch for development only (not the product path):
    FABRIC_RUNTIME=python $0 start
EOF
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "error: Docker is installed but the daemon is not reachable (start Docker / permissions)." >&2
    return 1
  fi
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "error: compose file missing: $COMPOSE_FILE" >&2
    return 1
  fi
}

require_inference_config() {
  if [[ -z "${DEFAULT_BASE_URL:-}" || -z "${DEFAULT_MODEL:-}" ]]; then
    echo "error: no inference endpoint configured for the fabric sidecar." >&2
    echo "  Run:  $ROOT/scripts/setup.sh --wizard   or   --manual" >&2
    echo "  Or set ZHC_FABRIC_DEFAULT_BASE_URL + ZHC_FABRIC_DEFAULT_MODEL" >&2
    return 1
  fi
}

compose() {
  # Pass through env for variable substitution in compose
  (cd "$ROOT/sidecar" && docker compose -f docker-compose.yml "$@")
}

# Models on the host: container cannot use 127.0.0.1 (that is the container itself).
dockerize_base_url() {
  local u="$1"
  u="${u//127.0.0.1/host.docker.internal}"
  u="${u//localhost/host.docker.internal}"
  printf '%s' "$u"
}

cmd_start_otp() {
  require_docker || return 1
  require_inference_config || return 1

  if is_docker_running && health >/dev/null; then
    echo "zhc-fabric OTP already running (docker: $CONTAINER_NAME) on http://${HOST}:${PORT}"
    health | head -c 500; echo
    return 0
  fi

  # Free stale Python sidecar if present
  if is_python_running; then
    echo "stopping leftover Python sidecar before OTP start..."
    cmd_stop_python || true
  fi

  # Export host-reachable URL for compose/container
  local docker_url
  docker_url="$(dockerize_base_url "$DEFAULT_BASE_URL")"
  export DEFAULT_BASE_URL="$docker_url"
  export ZHC_FABRIC_DEFAULT_BASE_URL="$docker_url"
  if [[ "$docker_url" != "${ZHC_FABRIC_DEFAULT_BASE_URL:-}" ]] || true; then
    echo "  model URL for container: $docker_url"
  fi

  echo "building/starting Erlang OTP sidecar via Docker (Erlang is inside the image)..."
  compose up -d --build
  # Wait for health
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if health >/dev/null; then
      echo "zhc-fabric started (runtime=otp docker=$CONTAINER_NAME) http://${HOST}:${PORT}"
      echo "  DEFAULT_BASE_URL=$DEFAULT_BASE_URL"
      echo "  DEFAULT_MODEL=$DEFAULT_MODEL"
      echo "  api_key=$([[ -n "${DEFAULT_API_KEY:-}" ]] && echo set || echo empty)"
      health; echo
      return 0
    fi
    sleep 0.5
  done
  echo "error: OTP container did not become healthy on :${PORT}" >&2
  compose logs --tail 40 2>/dev/null || true
  return 1
}

cmd_start_python() {
  require_inference_config || return 1
  if [[ ! -f "$STUB" ]]; then
    echo "error: Python stub not found at $STUB" >&2
    return 1
  fi
  if is_python_running && health >/dev/null; then
    echo "zhc-fabric Python stub already running (pid $(cat "$PID_FILE"))"
    health; echo
    return 0
  fi
  rm -f "$PID_FILE"
  nohup python3 "$STUB" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 0.4
  if health >/dev/null; then
    echo "zhc-fabric started (runtime=python pid=$(cat "$PID_FILE")) http://${HOST}:${PORT}"
    echo "  note: Python stub is a fallback — product path is Docker OTP"
    health; echo
    return 0
  fi
  echo "error: Python sidecar failed; see $LOG_FILE" >&2
  tail -n 30 "$LOG_FILE" 2>/dev/null || true
  return 1
}

cmd_start() {
  case "$RUNTIME" in
    python|stub) cmd_start_python ;;
    otp|docker|erlang|*) cmd_start_otp ;;
  esac
}

cmd_stop_python() {
  if is_python_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "stopped python pid $pid"
  else
    rm -f "$PID_FILE"
  fi
}

cmd_stop() {
  cmd_stop_python || true
  if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" ]]; then
    if is_docker_running || compose ps -q 2>/dev/null | grep -q .; then
      echo "stopping docker OTP sidecar..."
      compose down || true
    fi
  fi
  echo "stopped"
}

cmd_status() {
  echo "runtime preference: $RUNTIME (FABRIC_RUNTIME)"
  echo "config: DEFAULT_BASE_URL=${DEFAULT_BASE_URL:-<unset>} DEFAULT_MODEL=${DEFAULT_MODEL:-<unset>}"
  if [[ -f "$ENV_FILE" ]]; then
    echo "env_file: $ENV_FILE"
  else
    echo "env_file: (none — run scripts/setup.sh)"
  fi
  if is_docker_running; then
    echo "docker: running ($CONTAINER_NAME)"
  else
    echo "docker: not running"
  fi
  if is_python_running; then
    echo "python: running pid=$(cat "$PID_FILE")"
  else
    echo "python: not running"
  fi
  if out="$(health)"; then
    echo "health: $out"
  else
    echo "health: unreachable at http://${HOST}:${PORT}"
    return 1
  fi
}

cmd_logs() {
  local n="${1:-50}"
  if is_docker_running; then
    compose logs --tail "$n"
  elif [[ -f "$LOG_FILE" ]]; then
    tail -n "$n" "$LOG_FILE"
  else
    echo "no logs (container not running and no $LOG_FILE)"
  fi
}

usage() {
  cat <<EOF
usage: $0 {start|stop|status|restart|logs}

  Primary: Docker + Erlang/OTP image (no host Erlang install)
  Fallback: FABRIC_RUNTIME=python $0 start

  first-time: $ROOT/scripts/setup.sh
EOF
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  restart) cmd_stop || true; cmd_start ;;
  logs) cmd_logs "${2:-50}" ;;
  *) usage; exit 2 ;;
esac
