# zhc-fabric installed

## What you need on the host

| Required | Why |
|----------|-----|
| **Docker** | Runs the **Erlang/OTP** fabric image (the real product) |
| Model endpoint | Any OpenAI-compatible `/v1/chat/completions` |
| **Not required** | Installing Erlang, rebar, or hex on this machine |

OTP/Erlang is **inside the Docker image**. If Docker is missing, install Docker first — you will not be asked to install Erlang.

## Configure inference (wizard or manual)

```bash
# Interactive
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --wizard

# Or skip prompts — prints what to edit where
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --manual
```

Manual file (preferred): `~/.hermes/zhc-fabric/sidecar.env`

```bash
ZHC_FABRIC_DEFAULT_BASE_URL=http://host.docker.internal:11434/v1
# If the model is on the same machine, host.docker.internal is set by compose.
# From the host shell you may use http://127.0.0.1:11434/v1 in sidecar.env;
# install-sidecar maps it for Docker. Prefer host.docker.internal when unsure.
ZHC_FABRIC_DEFAULT_MODEL=llama3.2
ZHC_FABRIC_DEFAULT_API_KEY=
```

## Start the OTP sidecar (Docker)

```bash
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh start
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh status
~/.hermes/plugins/zhc-fabric/scripts/smoke.sh
```

## Hermes

```bash
hermes gateway restart   # if already running
# chat: /fabric status  ·  fabric_consensus
```

## If Docker is not installed

Install Docker Engine or Desktop, then re-run `install-sidecar.sh start`.  
Do **not** hunt for a system Erlang package — that is not the supported path.
