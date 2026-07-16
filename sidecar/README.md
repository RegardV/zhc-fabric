# Sidecar runtimes

| Path | Role |
|------|------|
| **`otp/` + Docker** | **Primary product runtime** — Erlang/OTP fabric |
| `stub/server.py` | Dev / test fallback only (`FABRIC_RUNTIME=python`) |

## Requirements (product path)

| Host need | Why |
|-----------|-----|
| **Docker** | Builds and runs the OTP image |
| **Not** Erlang | Image is `FROM erlang:27-alpine`; OTP stays in the container |
| Inference URL | OpenAI-compatible model reachable from the container (often via `host.docker.internal`) |

## Start (recommended)

```bash
../scripts/setup.sh --wizard          # or --manual
../scripts/install-sidecar.sh start
../scripts/install-sidecar.sh status
```

Compose is `docker-compose.yml` in this directory (OTP Dockerfile).

## Env

See root [README.md](../README.md) and [docs/SIDECAR-API.md](../docs/SIDECAR-API.md).
