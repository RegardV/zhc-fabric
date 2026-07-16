# zhc-fabric OTP sidecar (Phase 3)

Erlang/OTP 27 implementation of the sidecar API (`docs/SIDECAR-API.md`).
Same HTTP JSON contract as `sidecar/stub/server.py`; stdlib only (inets httpd,
httpc, built-in `json`) — no hex dependencies.

Supervision: top sup → lease gen_server (global completion cap +
stats), simple_one_for_one job supervisor (one temporary process per job,
parallel proposer/critic workers per vote), inets httpd listener.

## Build

```bash
docker build -t zhc-fabric-otp sidecar/otp
```

## Run

```bash
docker run --rm -p 7733:7733 \
  -e DEFAULT_BASE_URL=http://host:8000/v1 -e DEFAULT_MODEL=my-model \
  zhc-fabric-otp
```

## Verify against the contract test (from repo root)

```bash
docker run --rm -d --name fabric-otp --network=host \
  -e FABRIC_HOST=127.0.0.1 -e FABRIC_PORT=7739 zhc-fabric-otp
FABRIC_TEST_URL=http://127.0.0.1:7739 python3 tests/test_api_contract.py
docker rm -f fabric-otp
```
