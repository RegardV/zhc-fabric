# ZHC Fabric

**Sidecar multi-model consensus fabric for Hermes Agent** (any OpenAI-compatible stack).

Hermes stays the agent shell. This repo ships a **thin plugin** + an **independent sidecar** (Python stub or Erlang/OTP) that runs parallel propose / critique / vote. No Hermes core patches.

| Layer | Tech | Role |
|-------|------|------|
| Plugin | Python (`register(ctx)`) | Tools, `/fabric`, skill |
| Sidecar | `sidecar/stub` or `sidecar/otp` | HTTP `:7733` — fan-out + reduce |
| Inference | Your endpoints | llama.cpp, Ollama, cloud |

**Status:** Capped at Phase 4a — plugin + Python stub + OTP sidecar + real `love_eq` / metrics. Multi-node distribution deferred (v2+).

---

## Install (anyone with Hermes)

```bash
# From Git once published:
# hermes plugins install YourOrg/zhc-fabric --enable

# Local / dev:
ln -sfn /path/to/zhc-fabric ~/.hermes/plugins/zhc-fabric
hermes plugins enable zhc-fabric
```

During `hermes plugins install`, Hermes **prompts** for:

| Variable | What to enter |
|----------|----------------|
| `ZHC_FABRIC_DEFAULT_BASE_URL` | OpenAI-compatible base, e.g. `http://127.0.0.1:11434/v1` |
| `ZHC_FABRIC_DEFAULT_MODEL` | Model id, e.g. `llama3.2` |
| `ZHC_FABRIC_DEFAULT_API_KEY` | Optional — blank for most local servers |

Saved to `~/.hermes/.env` (skip empty if you prefer to configure later).

Then run the setup wizard (writes a local env file + starts the sidecar):

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh
```

Smoke + chat:

```bash
~/.hermes/plugins/zhc-fabric/scripts/smoke.sh
hermes gateway restart   # if gateway was already running
```

In chat: `/fabric status` · ask for a committee · tool `fabric_consensus`.

### Reconfigure

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh
# or edit:  ~/.hermes/zhc-fabric/sidecar.env
```

### Env reference

| Variable | Meaning |
|----------|---------|
| `ZHC_FABRIC_DEFAULT_BASE_URL` | Inference `/v1` base (install prompt) |
| `ZHC_FABRIC_DEFAULT_MODEL` | Model id |
| `ZHC_FABRIC_DEFAULT_API_KEY` | Optional API key |
| `DEFAULT_BASE_URL` / `DEFAULT_MODEL` / `DEFAULT_API_KEY` | Same, classic names (also work) |
| `ZHC_FABRIC_URL` | Plugin → sidecar (default `http://127.0.0.1:7733`) |
| `ZHC_FABRIC_AUTO_START` | Plugin may start sidecar on load (`1`/`true`) |
| `MAX_INFLIGHT_COMPLETIONS` | Concurrent outbound LLM calls (default `2`) |

Config files:

- `~/.hermes/zhc-fabric/sidecar.env` — written by `setup.sh` (mode 600)
- `~/.hermes/zhc-fabric/config.json` — non-secret summary

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

Slash: `/fabric status` · `/fabric start` · `/fabric setup` · `/fabric url`

---

## Architecture

```text
[Telegram / CLI / Desktop]
  → Hermes
      → zhc-fabric plugin
          → sidecar :7733
              → OpenAI-compatible models (URL/key from setup)
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
├── plugin.yaml / after-install.md / __init__.py / client.py / config.py
├── skill/SKILL.md
├── scripts/setup.sh | install-sidecar.sh | healthcheck.sh | smoke.sh
├── sidecar/stub/server.py
├── sidecar/docker-compose.yml
├── tests/
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
