# zhc-fabric OTP sidecar (primary runtime)

This is the **main fabric runtime**: Erlang/OTP 27 actors, supervision, leases,
same HTTP JSON API as `docs/SIDECAR-API.md`.

## You do **not** install Erlang on the host

| On your machine | Required? |
|-----------------|-----------|
| **Docker** | **Yes** — builds and runs this image |
| Erlang / rebar / hex | **No** — provided inside `erlang:27-alpine` |
| Python | Only for the Hermes plugin + optional tests |

The Dockerfile compiles the app with `erlc` at **image build** time. Users never
run `erlc` or install OTP themselves.

## Quick start (from repo / plugin root)

Prefer the install script (loads `~/.hermes/zhc-fabric/sidecar.env`):

```bash
./scripts/setup.sh --wizard    # or --manual
./scripts/install-sidecar.sh start
./scripts/install-sidecar.sh status
```

Direct Docker:

```bash
cd sidecar
export DEFAULT_BASE_URL=http://host.docker.internal:11434/v1
export DEFAULT_MODEL=llama3.2
export DEFAULT_API_KEY=   # optional
docker compose up -d --build
curl -sS http://127.0.0.1:7733/health | jq .
```

Manual image build:

```bash
docker build -t zhc-fabric-otp sidecar/otp
docker run --rm -p 7733:7733 \
  --add-host=host.docker.internal:host-gateway \
  -e DEFAULT_BASE_URL=http://host.docker.internal:11434/v1 \
  -e DEFAULT_MODEL=llama3.2 \
  --name zhc-fabric \
  zhc-fabric-otp
```

## Reach a model on the host

The container uses `host.docker.internal` (compose sets `extra_hosts`).
If your model listens only on `127.0.0.1` on the host, that is fine — the
gateway maps host loopback for the container.

Use a **real** host IP only if `host.docker.internal` fails on your OS.

## Env (same as product)

| Variable | Meaning |
|----------|---------|
| `DEFAULT_BASE_URL` / `ZHC_FABRIC_DEFAULT_BASE_URL` | OpenAI-compatible `…/v1` |
| `DEFAULT_MODEL` / `ZHC_FABRIC_DEFAULT_MODEL` | Model id |
| `DEFAULT_API_KEY` / `ZHC_FABRIC_DEFAULT_API_KEY` | Optional |
| `MAX_INFLIGHT_COMPLETIONS` | Default 2 |
| `FABRIC_PORT` | Host port (compose maps to 7733 in container) |

## Supervision layout

Top sup → lease gen_server → job supervisor (`simple_one_for_one`) → inets httpd.
Stdlib only (inets httpd/httpc, `json`) — zero hex dependencies.

## Contract test

```bash
# stop any :7733 fabric first, or use another port
docker run --rm -d --name fabric-otp --network=host \
  -e FABRIC_HOST=127.0.0.1 -e FABRIC_PORT=7739 \
  -e DEFAULT_BASE_URL=http://127.0.0.1:11434/v1 \
  -e DEFAULT_MODEL=llama3.2 \
  zhc-fabric-otp
FABRIC_TEST_URL=http://127.0.0.1:7739 python3 tests/test_api_contract.py
docker rm -f fabric-otp
```

## Python stub?

`sidecar/stub/` exists for offline unit tests and a **dev fallback** only:

```bash
FABRIC_RUNTIME=python ./scripts/install-sidecar.sh start
```

That is **not** the product path. The premise of zhc-fabric is the OTP sidecar.
