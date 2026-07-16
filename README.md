# ZHC Fabric

**Sidecar multi-model consensus fabric for Hermes Agent** (any OpenAI-compatible stack).

Hermes stays the agent shell. This repo ships a **thin plugin** + an **independent Python sidecar** (Erlang/OTP planned) that runs parallel propose / critique / vote. No Hermes core patches.

| Layer | Tech | Role |
|-------|------|------|
| Plugin | Python (`register(ctx)`) | Tools, `/fabric`, skill |
| Sidecar | `sidecar/stub/server.py` | HTTP `:7733` — fan-out + reduce |
| Inference | Your endpoints | llama.cpp, Ollama, cloud |

**Status:** MVP runnable (Phase 1 stub). OTP fabric is Phase 3 behind the same API.

---

## Quick start (this machine)

```bash
# 1. Install plugin into Hermes (symlink for dev)
ln -sfn ~/projects/zhc-fabric ~/.hermes/plugins/zhc-fabric

# 2. Enable in config (or: hermes plugins enable zhc-fabric)
#    plugins.enabled must include: zhc-fabric

# 3. Start sidecar (defaults: model endpoint :8000, model qwopus-3.6)
~/projects/zhc-fabric/scripts/install-sidecar.sh start

# 4. Smoke test
~/projects/zhc-fabric/scripts/smoke.sh

# 5. Restart Hermes gateway so tools load
systemctl --user restart hermes-gateway   # if applicable
```

In chat: `/fabric status` or ask the agent to call `fabric_consensus`.

### Env (optional)

```bash
export ZHC_FABRIC_URL=http://127.0.0.1:7733
export DEFAULT_BASE_URL=http://127.0.0.1:8000/v1
export DEFAULT_MODEL=qwopus-3.6
export MAX_INFLIGHT_COMPLETIONS=2
export ZHC_FABRIC_AUTO_START=1   # plugin may start sidecar on load
```

### Hermes config

```yaml
plugins:
  enabled:
    - zhc-fabric
```

---

## Tools

| Tool | Purpose |
|------|---------|
| `fabric_status` | Sidecar health |
| `fabric_consensus` | N parallel views + reduce (`majority` / `love_eq` / `unanimous_soft`) |
| `fabric_fanout` | N views, no reduce |

Slash: `/fabric status` · `/fabric start` · `/fabric url`

---

## Architecture

```text
[Telegram / CLI / Desktop]
  → Hermes
      → zhc-fabric plugin
          → sidecar :7733
              → OpenAI-compatible models
```

Docs:

| File | Purpose |
|------|---------|
| [docs/BUILD.md](./docs/BUILD.md) | Full build plan |
| [docs/PLUGIN-CONTRACT.md](./docs/PLUGIN-CONTRACT.md) | Hermes plugin surface |
| [docs/SIDECAR-API.md](./docs/SIDECAR-API.md) | HTTP API |
| [docs/PORTABILITY.md](./docs/PORTABILITY.md) | Any-install rules |

---

## Layout

```text
zhc-fabric/
├── plugin.yaml / __init__.py / client.py / config.py / schemas.py
├── skill/SKILL.md
├── scripts/install-sidecar.sh | healthcheck.sh | smoke.sh
├── sidecar/stub/server.py
├── sidecar/docker-compose.yml
├── tests/test_client.py
└── docs/
```

---

## API smoke

```bash
curl -sS http://127.0.0.1:7733/health | jq .

curl -sS http://127.0.0.1:7733/v1/consensus \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"What is 2+2? One short sentence.","n":2,"policy":"majority"}' | jq .
```

---

## License

MIT — see [LICENSE](./LICENSE).

## Maintainers

Zero-Human Company / garage lab.
