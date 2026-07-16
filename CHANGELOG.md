# Changelog

## 0.1.0 — 2026-07-16

### Product

- Hermes plugin: `fabric_status`, `fabric_consensus`, `fabric_fanout`, `/fabric`, skill
- **Primary runtime:** Erlang/OTP 27 sidecar via **Docker** (no host Erlang)
- Reduce policies: `majority`, `love_eq` (LLM rubric), `unanimous_soft`
- Global completion lease (`MAX_INFLIGHT_COMPLETIONS`)
- `/health`, `/v1/consensus`, `/v1/fanout`, `/v1/metrics`

### Install UX

- `scripts/setup.sh --wizard` / `--manual` (skip prompts + paths)
- `scripts/install-sidecar.sh` → Docker Compose OTP image by default
- Host loopback model URLs rewritten to `host.docker.internal` for the container
- `after-install.md` for Hermes plugin install
- Fail-open plugin (sidecar down does not break Hermes)

### Docs

- Full README (install, run, test, uninstall)
- API contract, plugin contract, portability, build phases
- Branding: zhc-fabric / RealAndWorks garage lab

### Not in 0.1.0

- Multi-node distribution
- Hermes credential-pool integration
- Multi-endpoint tool schema on Hermes tools (API `endpoints[]` still works via HTTP)
