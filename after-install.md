# zhc-fabric installed

Configure the **inference** endpoint (base URL, model, optional API key), then start the sidecar.

You can **skip all prompts** and edit files yourself, or use the interactive wizard.

## Option A — Manual (skip prompts)

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --manual
```

That prints exact paths and creates a template if needed. In short:

| What | Where |
|------|--------|
| **Preferred file** | `~/.hermes/zhc-fabric/sidecar.env` |
| **Template in repo** | `sidecar.env.example` |
| **Optional Hermes .env** | `~/.hermes/.env` (`hermes config env-path`) |

Set:

```bash
ZHC_FABRIC_DEFAULT_BASE_URL=http://127.0.0.1:11434/v1   # your OpenAI-compatible /v1
ZHC_FABRIC_DEFAULT_MODEL=llama3.2
ZHC_FABRIC_DEFAULT_API_KEY=                             # empty for most local servers
```

Then:

```bash
chmod 600 ~/.hermes/zhc-fabric/sidecar.env
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh start
~/.hermes/plugins/zhc-fabric/scripts/smoke.sh
```

## Option B — Interactive wizard

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --wizard
# or:  setup.sh   → choose 1) Interactive
```

Asks for URL / model / key, writes `sidecar.env`, starts the sidecar.

## Use from Hermes

- Restart gateway if it was already running: `hermes gateway restart`
- Chat: `/fabric status` · `fabric_consensus`

## Reconfigure later

```bash
setup.sh --wizard          # re-prompt
setup.sh --manual          # show edit paths again
# or edit:  ~/.hermes/zhc-fabric/sidecar.env
```
