# ZHC Fabric — Build Document

**Project:** `zhc-fabric`  
**Location:** `~/projects/zhc-fabric`  
**Audience:** implementers shipping a portable Hermes sidecar plugin + consensus fabric  
**Last updated:** 2026-07-16  

---

## 1. Problem statement

Local multi-agent systems (Hermes, ZHC-OS CTO profiles, OpenClaw-like stacks) already can:

- Talk to local models (e.g. llama.cpp / Qwopus)
- Delegate work to subagents
- Run gateways, cron, Kanban

In practice the **orchestration layer** becomes the ceiling:

- Python thread pools and GIL contention
- Heavy subagent processes for “ask three opinions”
- Serial pipelines where parallel critique would be natural
- Fragile multi-process recovery when something dies mid-committee

**Inference** (tokens/sec on GPU) is a separate problem — already handled by llama.cpp, Ollama, vLLM, etc. This project does **not** try to speed up kernels.

**This project** speeds up and hardens **committee-style orchestration**: many lightweight minds propose, critique, and vote; optionally across machines.

---

## 2. Goals

### 2.1 Must have

1. **Sidecar any Hermes install** — no fork of `hermes-agent`, no patches to core.
2. **Hermes plugin** that registers tools + optional slash command + skill.
3. **Stable HTTP API** between plugin and sidecar (`/health`, `/v1/consensus`, …).
4. **Fail open** — offline sidecar must not break Hermes startup or normal chat.
5. **Portable config** — `HERMES_HOME`, env vars, no hard-coded `~/qwen-qwopus` paths.
6. **OpenAI-compatible fan-out** — sidecar calls user-supplied `base_url` + `model`.
7. **Documented install** — `hermes plugins install` + sidecar start one-liners.

### 2.2 Should have

1. Concurrency leases so one GPU is not stampeded.
2. Pluggable reduce policies: `majority`, `love_eq`, `unanimous_soft`.
3. Docker Compose path for users without Erlang tooling.
4. `/fabric` slash command and `hermes fabric`-style CLI via plugin.
5. Metrics endpoint for latency and actor counts.

### 2.3 Later (v2+) — not in current cap

1. Multi-node Erlang distribution across LAN hosts (**explicitly deferred**).
2. Hot code reload of reduce policies.
3. Kanban card workers as fabric jobs.
4. Deeper ZHC joule ledger / Kanban hooks (Love Equation scoring as a reduce policy is already in Phase 4a).

### 2.4 Non-goals

- Replacing Hermes gateway, skills, memory, or dashboard.
- Shipping or managing GGUF weights.
- Becoming a general Kubernetes scheduler.
- Guaranteeing better single-model quality (only multi-view aggregation).

---

## 3. Success metrics

| Metric | Target (MVP) | Stretch |
|--------|--------------|---------|
| Install on clean Hermes | Plugin enable + sidecar start &lt; 10 min | One command |
| `fabric_status` when down | JSON error, HTTP tool success=false, no crash | — |
| 3-way consensus vs serial Python | Lower orchestration overhead; wall clock dominated by model | Near real-time feel on small prompts |
| GPU stampede | Max concurrent inference slots configurable (default 2) | Lease queue with priorities |
| Hermes update | Plugin still loads after `hermes update` | — |

---

## 4. Architecture

### 4.1 Logical view

```text
┌──────────────────────────────────────────────────────────────┐
│  Hermes (any install: CLI, gateway, desktop, ACP)            │
│                                                              │
│  plugins.enabled: [zhc-fabric]                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  zhc-fabric plugin (Python, stdlib HTTP)               │  │
│  │  tools: fabric_status, fabric_consensus, fabric_fanout │  │
│  │  cmd: /fabric                                          │  │
│  │  skill: when to call consensus                         │  │
│  └───────────────────────────┬────────────────────────────┘  │
└──────────────────────────────┼───────────────────────────────┘
                               │ HTTP JSON  (default :7733)
                               ▼
┌──────────────────────────────────────────────────────────────┐
│  Sidecar process (independent lifecycle)                     │
│                                                              │
│  MVP: Python asyncio stub  →  Production: Erlang/OTP actors  │
│                                                              │
│  • Fan-out N completion requests                             │
│  • Reduce by policy                                          │
│  • Supervision / restart (OTP)                               │
│  • Optional multi-node cluster                               │
└───────────────────────────┬──────────────────────────────────┘
                            │ OpenAI-compatible chat.completions
                            ▼
┌──────────────────────────────────────────────────────────────┐
│  User inference                                              │
│  e.g. http://127.0.0.1:8000/v1  model=qwopus-3.6             │
│  Ollama, OpenRouter, multiple base_urls per vote             │
└──────────────────────────────────────────────────────────────┘
```

### 4.2 Why not pure Python inside Hermes?

Hermes already has `delegate_task` + `ThreadPoolExecutor` and `max_concurrent_children`. That is good for **subagents with tools**. Consensus is different:

- Many short LLM calls, not full agent loops
- Need thousands of cheap waiting units (actors), not N full agent contexts
- Want independent lifecycle, crash isolation, later multi-node

Sidecar keeps Hermes thin and lets the fabric evolve without agent releases.

### 4.3 Relationship to local stack (example host)

On a typical Zero-Human / garage host this coexists with:

| Component | Role relative to fabric |
|-----------|-------------------------|
| Hermes gateway + dashboard | Face: messaging, tools, sessions |
| llama.cpp / Qwopus `:8000` / `:8080` | Inference backend for actors |
| Ollama (optional) | Alternate endpoints |
| ZHC-OS CTOs / Kanban | Consumers of consensus results |
| VoiceBox / other LAN services | Unrelated; fabric does not own them |

Fabric does **not** replace those services; it **calls** model endpoints they expose.

---

## 5. Component design

### 5.1 Hermes plugin

**Discovery path:** `~/.hermes/plugins/zhc-fabric/` (or project `.hermes/plugins/` with `HERMES_ENABLE_PROJECT_PLUGINS=true`).

**Manifest:** `plugin.yaml` — name `zhc-fabric`, version, description, provides_tools / hooks / commands.

**Entry:** `register(ctx)` in `__init__.py`:

| Registration | Name | Behavior |
|--------------|------|----------|
| Tool | `fabric_status` | GET sidecar `/health` |
| Tool | `fabric_consensus` | POST `/v1/consensus` |
| Tool | `fabric_fanout` | POST `/v1/fanout` (optional MVP+) |
| Command | `/fabric` | status / start help |
| Skill | `zhc-fabric` | Teach model when to use tools |
| Hook | `on_session_start` | Log if offline (optional, quiet) |

**Client:** `urllib` only (no new pip deps in MVP) so it loads inside any Hermes venv.

**Config resolution order:**

1. `ZHC_FABRIC_URL`
2. `$HERMES_HOME/zhc-fabric/config.json` → `url`
3. Default `http://127.0.0.1:7733`

**Auto-start:** only if `ZHC_FABRIC_AUTO_START=1|true|yes`; spawn `scripts/install-sidecar.sh start` best-effort; never raise from `register()`.

### 5.2 Sidecar

**Port:** `7733` default (`FABRIC_PORT`).

**MVP implementation strategy:**

| Phase | Sidecar runtime | Why |
|-------|-----------------|-----|
| Phase 0 | Python asyncio + http.server or FastAPI-in-stdlib-free aio | Prove plugin + API |
| Phase 1 | Erlang/OTP (rebar3 or mix if Elixir preferred) | Real actors + supervisors |
| Phase 2 | Multi-node | Distributed fabric |

**Actor roles (logical):**

| Actor | Job |
|-------|-----|
| `proposer` | First-pass answers |
| `critic` | Attack / improve proposals |
| `scorer` | Optional Love Equation / rubric scores |
| `aggregator` | Apply policy, emit final answer |
| `lease_manager` | Cap concurrent outbound LLM calls |

**Concurrency:** `max_inflight_completions` (default 2 on single consumer GPU). Extra work queues.

### 5.3 Reduce policies

| Policy | Behavior |
|--------|----------|
| `majority` | Cluster similar answers; pick plurality (simple string/heuristic or judge model) |
| `love_eq` | Score cooperation/creation vs damage/deception dimensions; pick max C−D (configurable rubric prompt) |
| `unanimous_soft` | Prefer agreement; if split, return structured dissent + best compromise |

MVP may implement `majority` with a final “judge” completion; others can be stubs that fall back to majority with a warning field.

---

## 6. HTTP API (summary)

Full detail: [SIDECAR-API.md](./SIDECAR-API.md).

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness + version + actor stats |
| `POST` | `/v1/consensus` | Fan-out + reduce |
| `POST` | `/v1/fanout` | Fan-out only |
| `GET` | `/v1/metrics` | Optional Prometheus-ish or JSON counters |

### 6.1 Consensus request (sketch)

```json
{
  "prompt": "Should we migrate billing to …?",
  "n": 3,
  "policy": "majority",
  "timeout_ms": 120000,
  "endpoints": [
    {
      "name": "local-a",
      "base_url": "http://127.0.0.1:8000/v1",
      "model": "qwopus-3.6",
      "api_key": ""
    }
  ],
  "system_prompt": "optional override"
}
```

If `endpoints` omitted, sidecar uses `DEFAULT_BASE_URL` / `DEFAULT_MODEL` from environment.

### 6.2 Consensus response (sketch)

```json
{
  "ok": true,
  "answer": "…",
  "policy": "majority",
  "votes": [
    {"role": "proposer", "model": "qwopus-3.6", "text": "…"},
    {"role": "critic", "model": "qwopus-3.6", "text": "…"}
  ],
  "elapsed_ms": 4120,
  "error": null
}
```

Errors always JSON with `ok: false` and `error` string (reachable from plugin tool handler).

---

## 7. Build phases

### Phase 0 — Scaffold + contract (docs + empty plugin)  ✅ docs start here

- [x] Repo under `~/projects/zhc-fabric`
- [x] README + BUILD + contracts
- [x] `plugin.yaml`, `__init__.py` stubs that call a dead port safely
- [x] `scripts/healthcheck.sh`
- [x] LICENSE choice

**Exit:** Developer can drop plugin into `~/.hermes/plugins/zhc-fabric` and enable it without crashing Hermes.

### Phase 1 — MVP sidecar stub (Python)

- [x] Minimal HTTP server implementing `/health` + `/v1/consensus` (threads, stdlib-only)
- [x] Parallel N completions with global semaphore lease (`MAX_INFLIGHT_COMPLETIONS`)
- [x] `majority` via judge call with majority-pick fallback
- [x] `docker-compose.yml` optional
- [x] Plugin tools fully wired
- [x] Skill markdown
- [x] Offline integration test vs mock OpenAI server (`tests/test_api_contract.py`); live manual test pending local endpoint

**Exit:** From Hermes chat, `fabric_consensus` returns multi-view answer against real local model.

### Phase 2 — Packaging

- [x] `scripts/install-sidecar.sh` start|stop|status|logs
- [x] README install for Docker and native
- [x] GitHub-ready layout for `hermes plugins install owner/zhc-fabric`
- [x] Version pin: plugin version ↔ API `/v1`
- [x] Smoke test script `scripts/smoke.sh` (+ `scripts/test.sh` for the offline suite)

**Exit:** Clean machine install documented and reproducible.

### Phase 3 — Erlang/OTP fabric

- [x] OTP app (erlc-only build, zero hex deps): HTTP API preserved
- [x] One process per in-flight consensus job (`simple_one_for_one` job supervisor)
- [x] Actor processes for proposer/critic votes; policy/aggregation module
- [x] Supervision tree; crash of one job does not kill node
- [x] Replace Python stub behind same port/API (verified: `FABRIC_TEST_URL` contract test passes vs Docker OTP sidecar)
- [x] Config for `max_inflight_completions` (lease gen_server)

**Exit:** Same plugin, no tool schema changes; only sidecar binary/image changes.

### Phase 4a — Love Equation + metrics  ✅ shipped (cap)

- [x] `love_eq` policy with configurable rubric (LLM scorer pass in both runtimes; request `rubric` > `FABRIC_LOVE_EQ_RUBRIC` > default; heuristic fallback on scorer failure)
- [x] Optional metrics export (`/v1/metrics` JSON counters in both runtimes)

**Exit (met):** Same plugin; real `love_eq` reduce on both stub and OTP; live-verified on this host.

### Phase 4b+ — deferred (not in this cap)

- [ ] Multi-node connect (LAN) — **dropped for now**; stays a v2+ idea under §2.3
- [ ] ZHC Kanban / joule hooks (out of band; needs workspace conventions)

**Cap decision (2026-07-16):** Project is complete at Phase 4a. Do not start multi-node distribution until deliberately reopened.

---

## 8. Repository layout (implementers)

```text
zhc-fabric/
├── README.md
├── LICENSE
├── docs/
│   ├── BUILD.md              ← this file
│   ├── PLUGIN-CONTRACT.md
│   ├── SIDECAR-API.md
│   └── PORTABILITY.md
├── plugin.yaml
├── __init__.py
├── client.py
├── config.py
├── schemas.py
├── skill/
│   └── SKILL.md
├── scripts/
│   ├── install-sidecar.sh
│   ├── healthcheck.sh
│   └── smoke.sh
├── sidecar/
│   ├── README.md
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── stub/                 # Phase 1 Python
│   └── otp/                  # Phase 3 Erlang
└── tests/
    ├── test_client.py
    └── test_api_contract.py
```

---

## 9. Configuration reference

### 9.1 Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `ZHC_FABRIC_URL` | `http://127.0.0.1:7733` | Plugin → sidecar base URL |
| `ZHC_FABRIC_AUTO_START` | unset/false | Plugin tries to start sidecar |
| `ZHC_FABRIC_TIMEOUT_S` | `120` | Client timeout |
| `FABRIC_PORT` | `7733` | Sidecar listen port |
| `DEFAULT_BASE_URL` | (required for empty request endpoints) | Inference base |
| `DEFAULT_MODEL` | (required same) | Model id |
| `DEFAULT_API_KEY` | empty | Optional |
| `MAX_INFLIGHT_COMPLETIONS` | `2` | Global LLM concurrency |

### 9.2 Files

| Path | Purpose |
|------|---------|
| `$HERMES_HOME/plugins/zhc-fabric/` | Installed plugin |
| `$HERMES_HOME/zhc-fabric/config.json` | Optional `{ "url": "…" }` |
| `$HERMES_HOME/config.yaml` → `plugins.enabled` | Must list `zhc-fabric` |

### 9.3 Hermes config snippet

```yaml
plugins:
  enabled:
    - zhc-fabric
  disabled: []
```

---

## 10. Security

1. **Local by default** — bind `127.0.0.1` unless user opts into LAN.
2. **No secrets in git** — API keys via env or request body from Hermes env.
3. **Opt-in plugin** — Hermes does not load general plugins until `plugins.enabled`.
4. **Do not override built-in tools** — only new tool names (`fabric_*`).
5. **Prompt injection** — consensus votes are model output; treat as untrusted text when feeding back to Hermes.
6. **Resource abuse** — enforce `n` max (e.g. 8) and timeouts on sidecar.
7. **Supply chain** — pin Docker base images; document install trust (`hermes plugins install` from known org).

---

## 11. Testing plan

| Level | What |
|-------|------|
| Unit | `client.py` error paths (connection refused, timeout, bad JSON) |
| Contract | OpenAPI or golden JSON for request/response |
| Integration | Sidecar + mock OpenAI server (no GPU) |
| Live | Sidecar + real local model; 3-way consensus |
| Hermès | Enable plugin, `/fabric status`, tool call in CLI session |
| Regression | Hermes still chats when port 7733 closed |

---

## 12. Open-source narrative (product)

Positioning for public launch:

> **Hermes** is the self-improving agent shell.  
> **ZHC Fabric** is the parallel consensus + (later) distributed compute fabric under it.  
> **Your models** remain yours — any OpenAI-compatible endpoint.

Marketing claims must stay honest:

- Speedup is **orchestration / multi-view fluidity**, not magic token rates.
- Erlang shines at **actors, supervision, distribution** — prove that with Phase 3+ benchmarks.
- Ship a boring HTTP contract so other clients (not only Hermes) can use the fabric.

---

## 13. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Single GPU saturation | Leases + low default inflight |
| Plugin API drift in Hermes | Stick to documented `ctx.register_*`; CI against recent hermes-agent |
| Erlang adoption friction | Phase 1 Python stub; Docker image for OTP |
| Users expect free quality gains | Skill text: when consensus helps vs wastes tokens |
| Port conflicts | Configurable port; health clearly reports bind URL |

---

## 14. Acceptance criteria (MVP ship)

1. Fresh Hermes user can install plugin and enable it without errors.
2. With sidecar down: `fabric_status` → `success: false`, Hermes otherwise healthy.
3. With sidecar up + valid `DEFAULT_BASE_URL`: `fabric_consensus` returns `ok: true` and non-empty `answer`.
4. No modifications required under `hermes-agent` git tree.
5. Docs: README install, BUILD phases, API contract, portability checklist all present.
6. `n` capped; timeout enforced; no unbounded thread/process spawn in plugin.

---

## 15. Status at cap (Phase 4a)

**Done:** Phases 0–3 + 4a (plugin, Python stub, OTP sidecar, `love_eq`, metrics).

**Operate:**

1. Offline suite: `scripts/test.sh`
2. Live smoke: `scripts/smoke.sh` (sidecar + `DEFAULT_BASE_URL`)
3. Hermes: plugin enabled; `/fabric status` / `fabric_consensus`
4. OTP optional: Docker image under `sidecar/otp` (same API)

**Not next:** multi-node LAN fabric (deferred).

---

## 16. References (local context)

- Hermes plugins: `hermes-agent` docs → User Guide → Plugins; Developer Guide → Build a Plugin.
- User plugin example on this host: `~/.hermes/plugins/fusion-memory/`.
- Local inference notes: `~/.hermes/local_infrastructure.md` (Qwopus channels).
- ZHC company workspace: `~/zhc-os` (Love Equation alignment, CTOs) — consumer, not dependency.

---

## 17. Decision log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-16 | Sidecar + thin Hermes plugin, not core fork | Survives updates; portable to any install |
| 2026-07-16 | HTTP JSON contract first, Erlang second | Ship value; OTP is replaceable backend |
| 2026-07-16 | Default port 7733 | Avoid clash with 8000/8080/11434/9123 Hermes/llm |
| 2026-07-16 | Cap at Phase 4a; drop multi-node WIP | Ship single-node fabric with real `love_eq`; distribution stays v2+ |
| 2026-07-16 | Stdlib-only plugin client | No venv dependency fights |
| 2026-07-16 | Fail open | Agent availability &gt; fabric availability |
