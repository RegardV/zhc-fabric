# Sidecar runtimes

| Path | Status |
|------|--------|
| `stub/server.py` | **MVP** — Python stdlib HTTP, OpenAI-compatible fan-out |
| OTP / Erlang | Planned Phase 3 — same HTTP API on port 7733 |
| Docker | `docker compose up` from this directory |

## Native start

```bash
export DEFAULT_BASE_URL=http://127.0.0.1:8000/v1
export DEFAULT_MODEL=qwopus-3.6
../scripts/install-sidecar.sh start
```

## Env

See `docs/BUILD.md` §9 and `docs/SIDECAR-API.md`.
