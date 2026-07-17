# zhc-fabric

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Hermes plugin](https://img.shields.io/badge/Hermes-plugin-8A2BE2)](https://github.com/NousResearch/hermes-agent)
[![Runtime](https://img.shields.io/badge/runtime-Erlang%2FOTP%20via%20Docker-red)](./sidecar/otp/README.md)
[![API](https://img.shields.io/badge/API-v1-informational)](./docs/SIDECAR-API.md)

**Sidecar multi-model consensus fabric for [Hermes Agent](https://github.com/NousResearch/hermes-agent).**

Run a lightweight “committee” of parallel LLM views (propose / critique / vote), then reduce them to one answer—without forking Hermes or patching its core.

| Layer | What it is | Default |
|-------|------------|---------|
| **Hermes plugin** | Tools, `/fabric` command, skill | `~/.hermes/plugins/zhc-fabric` |
| **Sidecar** | **Erlang/OTP** fabric in **Docker** | `http://127.0.0.1:7733` |
| **Your models** | Any OpenAI-compatible `/v1/chat/completions` | Ollama, llama.cpp, OpenRouter, cloud, … |

**Repo:** https://github.com/RegardV/zhc-fabric · **License:** MIT · **v0.1.0** · [Real And Works garage lab](www.realandworks.com)]

### Quick start

```bash
# Requires: Docker (running) + Hermes. Does NOT require host Erlang.
hermes plugins install RegardV/zhc-fabric --enable
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --wizard   # or --manual
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh start
~/.hermes/plugins/zhc-fabric/scripts/smoke.sh
hermes gateway restart   # if already running
# chat: /fabric status
```

---

## Table of contents

1. [What this is](#what-this-is)
2. [Why it exists](#why-it-exists)
3. [What problem it solves](#what-problem-it-solves)
4. [What it is not](#what-it-is-not)
5. [Requirements](#requirements)
6. [Install](#install)
7. [Configure (wizard or manual)](#configure-wizard-or-manual)
8. [Run](#run)
9. [Use from Hermes](#use-from-hermes)
10. [Test](#test)
11. [Configuration reference](#configuration-reference)
12. [Architecture](#architecture)
13. [HTTP API (quick)](#http-api-quick)
14. [Troubleshooting](#troubleshooting)
15. [Security notes](#security-notes)
16. [Limitations & roadmap](#limitations--roadmap)
17. [Uninstall / remove](#uninstall--remove)
18. [Development](#development)
19. [Build log](#build-log)
20. [Docs & license](#docs--license)

---

## What this is

**zhc-fabric** is two pieces that ship in one repo:

1. A **Hermes plugin** (thin Python client) that registers tools, `/fabric`, and a skill.
2. An **Erlang/OTP sidecar** — the real product — run as a **Docker image**:
   - Actors + supervision for parallel propose / critique / vote
   - Global lease so one GPU/API is not stampeded
   - Reduce policies: `majority`, `love_eq`, `unanimous_soft`
   - Stable HTTP JSON API on port **7733**

**Docker is required. Installing Erlang on the host is not.** The image is built from `erlang:27-alpine`; OTP stays inside the container.

Hermes remains the chat/agent shell. If the sidecar is down, Hermes still works; fabric tools fail cleanly (`success: false`).

```text
You (CLI / Telegram / Desktop)
        │
        ▼
     Hermes  (plugin only — thin HTTP client)
        │  fabric_* tools  ·  /fabric
        ▼
  Docker container  zhc-fabric  (Erlang/OTP)
        :7733  ──chat.completions──►  Your model(s)
```

---

## Why it exists

Local multi-agent stacks (Hermes, similar agents) can already talk to models and spawn subagents. In practice the **orchestration** layer becomes the bottleneck for “ask three opinions and pick one”:

- Full subagent processes are heavy for short multi-view answers
- Serial “think again” loops waste wall-clock time when views could run in parallel
- Stuffing more threads into the agent process couples reliability, restarts, and resource limits to chat

**Inference speed** (tokens/sec) is a different problem—llama.cpp, Ollama, vLLM already handle that.

zhc-fabric exists to put that committee in **Erlang/OTP** (actors, supervision, leases) behind a boring HTTP API, delivered as a **Docker image** so anyone with Docker can run it—without becoming an Erlang packager. Hermes stays thin and fail-open.

---

## What problem it solves

| Pain | How fabric helps |
|------|------------------|
| “I want several independent takes before deciding” | `fabric_consensus` runs N views, then reduces |
| “I want raw dissent without a forced winner” | `fabric_fanout` |
| “Don’t crash my agent if the committee is offline” | Fail-open plugin; tools return JSON errors |
| “Don’t fork Hermes to get this” | Standard plugin + HTTP contract |
| “One GPU / one API key—don’t stampede it” | Global lease (`MAX_INFLIGHT_COMPLETIONS`, default 2) |
| “I care about cooperation vs damage, not just majority” | `love_eq` policy (LLM rubric scorer, heuristic fallback) |

**Good fits:** architecture tradeoffs, risk review, high-stakes wording, “what could go wrong,” Love Equation–style scoring.

**Bad fits:** trivial facts, latency-sensitive chitchat, tasks that need shell/browser tools (the fabric only does LLM fan-out).

---

## What it is not

- Not a Hermes fork or core patch  
- Not a model host (you bring Ollama / llama.cpp / cloud)  
- Not multi-node LAN clustering (deferred; single host only in this release)  
- Not Hermes **credential pools**—the sidecar uses its own URL/key config (see [Limitations](#limitations--roadmap))  
- Not a guarantee of better answers—only multi-view aggregation  

---

## Requirements

### You need these (host)

| Need | Why |
|------|-----|
| [Hermes Agent](https://github.com/NousResearch/hermes-agent) | Loads the plugin |
| **Docker** (Engine or Desktop) | **Builds and runs the OTP fabric** — this is the product path |
| `curl` | Health / smoke scripts |
| An OpenAI-compatible API | Sidecar calls `POST …/v1/chat/completions` |
| Python 3 | Hermes plugin only (stdlib HTTP client); **not** the fabric runtime |

### You do **not** need these

| Not required | Why |
|--------------|-----|
| **Erlang / OTP on the host** | Shipped **inside** the Docker image (`erlang:27-alpine` + `erlc` at build) |
| rebar3 / hex / Elixir | Zero host toolchain |
| GPU on the fabric host | Models can be remote; fabric is orchestration |

If install “hits a wall,” it should be **install Docker**, never **install Erlang**.

### Optional

| Optional | Why |
|----------|-----|
| `pytest` | Offline contract suite (`scripts/test.sh`) |
| `FABRIC_RUNTIME=python` | Dev-only Python stub fallback — **not** the product path |

---

## Install

End-to-end product path:

```bash
# 0. Docker must be installed and running
docker info

# 1. Plugin
hermes plugins install RegardV/zhc-fabric --enable

# 2. Model URL / key (wizard or manual — see below)
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --wizard

# 3. Start OTP sidecar (docker compose build + run)
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh start
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh status

# 4. Smoke + Hermes
~/.hermes/plugins/zhc-fabric/scripts/smoke.sh
hermes gateway restart   # if gateway was already running
```

That clones into `~/.hermes/plugins/zhc-fabric`. Install does **not** force URL/key prompts; `setup.sh` handles configuration.

### Dev / local symlink

```bash
git clone https://github.com/RegardV/zhc-fabric.git
ln -sfn "$(pwd)/zhc-fabric" ~/.hermes/plugins/zhc-fabric
hermes plugins enable zhc-fabric
```

### Confirm enablement

```yaml
# ~/.hermes/config.yaml  (or your profile)
plugins:
  enabled:
    - zhc-fabric
```

```bash
hermes plugins list
```

---

## Configure (wizard or manual)

The sidecar needs an inference **base URL**, **model id**, and optionally an **API key**.

Plugin root after install:

```text
~/.hermes/plugins/zhc-fabric/
```

### Option A — Interactive wizard

Prompts for URL, model, optional key; writes config; starts the sidecar.

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --wizard
```

Or run without flags and choose **1) Interactive**:

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh
```

### Option B — Manual (skip prompts)

Prints exact files and variables, and creates a template if missing:

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh --manual
```

**Where to edit**

| File | Purpose |
|------|---------|
| `~/.hermes/zhc-fabric/sidecar.env` | **Preferred** fabric config (mode `600`) |
| `sidecar.env.example` in the plugin | Template to copy |
| `~/.hermes/.env` | Optional; path via `hermes config env-path` |

**What to set**

```bash
# ~/.hermes/zhc-fabric/sidecar.env
ZHC_FABRIC_DEFAULT_BASE_URL=http://127.0.0.1:11434/v1
ZHC_FABRIC_DEFAULT_MODEL=llama3.2
ZHC_FABRIC_DEFAULT_API_KEY=          # leave empty for most local servers

# Classic aliases also work:
# DEFAULT_BASE_URL / DEFAULT_MODEL / DEFAULT_API_KEY
```

**Examples**

| Backend | Base URL | Model | Key |
|---------|----------|-------|-----|
| Ollama | `http://127.0.0.1:11434/v1` | `llama3.2` | empty |
| llama.cpp server | `http://127.0.0.1:8000/v1` | your model id | empty |
| OpenRouter | `https://openrouter.ai/api/v1` | `openai/gpt-4o-mini` | `sk-or-…` |

```bash
chmod 600 ~/.hermes/zhc-fabric/sidecar.env
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh start   # Docker OTP
```

**Localhost models + Docker:** if you set `http://127.0.0.1:…/v1` in `sidecar.env`, `install-sidecar.sh` rewrites it to `host.docker.internal` for the container so the model on the host is reachable.

### Reconfigure later

```bash
setup.sh --wizard    # re-prompt
setup.sh --manual    # show paths again
# or edit: ~/.hermes/zhc-fabric/sidecar.env
```

From Hermes chat: `/fabric setup` prints the same paths (editing still needs a terminal).

---

## Run

### Start / stop / status / logs (OTP via Docker)

```bash
PLUGIN=~/.hermes/plugins/zhc-fabric

$PLUGIN/scripts/install-sidecar.sh start     # docker compose build + up
$PLUGIN/scripts/install-sidecar.sh status    # should show runtime=otp / docker
$PLUGIN/scripts/install-sidecar.sh logs
$PLUGIN/scripts/install-sidecar.sh stop
$PLUGIN/scripts/install-sidecar.sh restart
```

What `start` does:

1. Checks **Docker** is installed and the daemon is up  
2. Loads `~/.hermes/zhc-fabric/sidecar.env`  
3. `docker compose -f sidecar/docker-compose.yml up -d --build`  
4. Image builds Erlang sources with `erlc` **inside** the container  
5. Waits for `GET http://127.0.0.1:7733/health`

Quick health:

```bash
$PLUGIN/scripts/healthcheck.sh
curl -sS http://127.0.0.1:7733/health | jq .
# expect something like: "runtime" mentioning otp, "ok": true
```

### Auto-start from the plugin (optional)

```bash
export ZHC_FABRIC_AUTO_START=1
```

When set, `register()` best-effort runs `install-sidecar.sh start` (still needs Docker). Prefer explicit start on servers.

### Direct Docker (same image)

```bash
cd ~/.hermes/plugins/zhc-fabric   # or your clone
cd sidecar
export DEFAULT_BASE_URL=http://host.docker.internal:11434/v1
export DEFAULT_MODEL=llama3.2
docker compose up -d --build
```

Details: [sidecar/otp/README.md](./sidecar/otp/README.md).

### Dev-only Python stub (not the product path)

```bash
FABRIC_RUNTIME=python ./scripts/install-sidecar.sh start
```

Use for quick offline experiments without Docker. **Production / “the premise” is Docker + OTP.**

---

## Use from Hermes

### Slash command

| Command | Effect |
|---------|--------|
| `/fabric status` | Sidecar health JSON |
| `/fabric start` | Try to start the sidecar |
| `/fabric setup` | Print wizard/manual paths |
| `/fabric url` | Plugin → sidecar URL |

### Tools (agent-callable)

| Tool | Purpose |
|------|---------|
| `fabric_status` | Is the fabric up? |
| `fabric_consensus` | N views + reduce → one `answer` |
| `fabric_fanout` | N views, no reduce |

**Example tool arguments**

```json
{
  "prompt": "Should we bind services to 127.0.0.1 by default? Short answer + one risk.",
  "n": 3,
  "policy": "majority",
  "timeout_s": 120
}
```

**Policies**

| Policy | Behavior |
|--------|----------|
| `majority` | Prefer agreement / judge-style pick among votes |
| `love_eq` | Extra scorer rates C (cooperation/creation) vs D (damage/deception); max `C−D` wins; rubric configurable; heuristic fallback on scorer failure |
| `unanimous_soft` | Prefer agreement; keep structured dissent when split |

**How the agent should present results:** lead with `answer`; summarize real dissent from `votes[]`; if `success`/`ok` is false, report `error` and continue with normal single-model reasoning.

### Direct HTTP (no Hermes)

```bash
curl -sS http://127.0.0.1:7733/v1/consensus \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "What is 2+2? One short sentence.",
    "n": 2,
    "policy": "majority"
  }' | jq .
```

Advanced: pass multiple `endpoints[]` in the JSON body for multi-model fan-out (API-level). Hermes tools currently use the sidecar’s default single endpoint from env/config—not Hermes credential pools.

---

## Test

### Offline (no GPU, mock OpenAI)

From a clone or the installed plugin tree:

```bash
# needs: pip install pytest  (or your env’s pytest)
./scripts/test.sh
```

Runs unit + contract tests (health, consensus, fanout, `love_eq` rubric shape). Expect **3 passed**.

### Live smoke (real model)

Requires: configured `sidecar.env` (or env vars), reachable model, sidecar startable.

```bash
./scripts/smoke.sh
```

Starts sidecar if needed, checks health, runs `n=2` majority consensus, asserts a non-empty answer.

### Manual curl checklist

```bash
curl -sS http://127.0.0.1:7733/health | jq .
curl -sS http://127.0.0.1:7733/v1/metrics | jq .
# consensus as above
```

### Fail-open check

```bash
./scripts/install-sidecar.sh stop
# Hermes: /fabric status  → error / ok false, chat still works
./scripts/install-sidecar.sh start
```

### OTP contract (Docker image)

```bash
docker build -t zhc-fabric-otp sidecar/otp
docker run --rm -d --name fabric-otp --network=host \
  -e FABRIC_HOST=127.0.0.1 -e FABRIC_PORT=7739 \
  -e DEFAULT_BASE_URL=http://127.0.0.1:11434/v1 \
  -e DEFAULT_MODEL=llama3.2 \
  zhc-fabric-otp
FABRIC_TEST_URL=http://127.0.0.1:7739 python3 tests/test_api_contract.py
docker rm -f fabric-otp
```

---

## Configuration reference

### Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `ZHC_FABRIC_DEFAULT_BASE_URL` | — | Inference base (`…/v1`) |
| `ZHC_FABRIC_DEFAULT_MODEL` | — | Model id |
| `ZHC_FABRIC_DEFAULT_API_KEY` | empty | Bearer token if required |
| `DEFAULT_BASE_URL` / `DEFAULT_MODEL` / `DEFAULT_API_KEY` | — | Same (classic names) |
| `ZHC_FABRIC_URL` | `http://127.0.0.1:7733` | Plugin → sidecar |
| `ZHC_FABRIC_TIMEOUT_S` | `120` | Plugin client timeout |
| `ZHC_FABRIC_AUTO_START` | off | Plugin may spawn sidecar |
| `FABRIC_HOST` / `FABRIC_PORT` | `127.0.0.1` / `7733` | Host port published by Docker |
| `MAX_INFLIGHT_COMPLETIONS` | `2` | Global concurrent LLM calls |
| `FABRIC_MAX_N` | `8` | Max votes per job |
| `FABRIC_LOVE_EQ_RUBRIC` | built-in | Override love_eq scorer instructions |
| `HERMES_HOME` | `~/.hermes` | Hermes state root |
| `FABRIC_RUNTIME` | `otp` | `otp` = Docker Erlang (default); `python` = stub fallback |

### Files on disk

| Path | Role |
|------|------|
| `~/.hermes/plugins/zhc-fabric/` | Installed plugin |
| `~/.hermes/zhc-fabric/sidecar.env` | Inference secrets/config (prefer mode `600`) |
| `~/.hermes/zhc-fabric/config.json` | Non-secret summary (from wizard) |
| `~/.hermes/zhc-fabric/sidecar.pid` | Sidecar PID |
| `~/.hermes/zhc-fabric/sidecar.log` | Sidecar log |
| `~/.hermes/config.yaml` | Must list `zhc-fabric` under `plugins.enabled` |
| `~/.hermes/.env` | Optional home for `ZHC_FABRIC_DEFAULT_*` |

---

## Architecture

```text
┌─────────────────────────────────────────┐
│  Hermes (any install)                   │
│  plugins.enabled: [zhc-fabric]          │
│  ┌───────────────────────────────────┐  │
│  │ plugin: client.py + tools/cmd     │  │
│  └─────────────────┬─────────────────┘  │
└────────────────────┼────────────────────┘
                     │ HTTP JSON :7733
                     ▼
┌─────────────────────────────────────────┐
│  Docker: zhc-fabric (Erlang/OTP 27)     │
│  · lease gen_server / max inflight      │
│  · supervised jobs: fan-out → reduce    │
│  · /health /v1/consensus /v1/fanout     │
│  · /v1/metrics                          │
└────────────────────┬────────────────────┘
                     │ chat.completions
                     ▼
              Your model endpoint
```

**Runtimes**

| Runtime | Path | Role |
|---------|------|------|
| **Erlang/OTP + Docker** | `sidecar/otp/` + compose | **Primary product** |
| Python stub | `sidecar/stub/server.py` | Tests / `FABRIC_RUNTIME=python` only |

---

## HTTP API (quick)

Full contract: [docs/SIDECAR-API.md](./docs/SIDECAR-API.md).

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness + stats |
| `POST` | `/v1/consensus` | Fan-out + reduce |
| `POST` | `/v1/fanout` | Fan-out only |
| `GET` | `/v1/metrics` | JSON counters |

Errors prefer HTTP 200 with `"ok": false` and an `error` string so clients always parse JSON.

---

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `Docker is required…` | Install/start Docker; **do not** install system Erlang |
| `daemon is not reachable` | Start Docker Desktop / `systemctl start docker`; check group perms |
| `fabric unreachable` | `install-sidecar.sh start`; `status`; `logs` |
| `no endpoints configured` | `setup.sh --wizard` or edit `sidecar.env` |
| Model connection refused from fabric | Use host model + rewrite: script maps `127.0.0.1` → `host.docker.internal` |
| Model 401 | Set API key in `sidecar.env` |
| Tools missing in Hermes | Enable plugin; `hermes gateway restart` |
| Port 7733 in use | Free port or set `FABRIC_PORT` + `ZHC_FABRIC_URL` |
| Slow / timeouts | Raise timeouts; lower `n`; check model |
| GPU overload | Lower `MAX_INFLIGHT_COMPLETIONS` and/or `n` |

---

## Security notes

- Sidecar binds **127.0.0.1** by default—local only.
- Keep API keys in `sidecar.env` or Hermes `.env` with restrictive permissions (`chmod 600`). **Do not commit secrets.**
- Model outputs are untrusted text when fed back into Hermes.
- No auth on the fabric HTTP port—do not expose `:7733` to the internet without a reverse proxy and your own access control.
- Plugin must not override Hermes built-in tools; only `fabric_*` names.

---

## Limitations & roadmap

**Shipped (Phase 4a cap)**

- Hermes plugin + **Docker Erlang/OTP sidecar (primary)**  
- Python stub only as test/dev fallback  
- Policies: `majority`, `love_eq` (real rubric pass), `unanimous_soft`  
- Metrics, leases, offline contract tests, setup wizard/manual  

**Not in this release**

- Multi-node Erlang distribution  
- Using Hermes **credential pools** / mid-session `/model` automatically for votes (sidecar has its own URL/key)  
- Multi-endpoint lists exposed on Hermes tool schemas (API `endpoints[]` works via curl)  
- ZHC Kanban / joule ledger hooks  

Honest positioning: speedup is **orchestration / multi-view fluidity**, not magic token rates.

---

## Uninstall / remove

### 1. Stop the sidecar

```bash
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh stop
# removes compose stack (container zhc-fabric)
```

### 2. Disable and remove the plugin

```bash
hermes plugins disable zhc-fabric
hermes plugins remove zhc-fabric
# equivalents: hermes plugins rm | uninstall
```

Or manually:

```bash
# remove enable entry from ~/.hermes/config.yaml plugins.enabled
rm -rf ~/.hermes/plugins/zhc-fabric
# if you used a symlink, only remove the link—not necessarily the clone
```

### 3. Optional: wipe local fabric state

```bash
rm -rf ~/.hermes/zhc-fabric
# sidecar.env, pid, logs, config.json
```

Optional: remove `ZHC_FABRIC_*` lines from `~/.hermes/.env` (`hermes config env-path`).

### 4. Restart Hermes

```bash
hermes gateway restart
```

Hermes chat continues normally without the plugin.

---

## Development

```bash
git clone https://github.com/RegardV/zhc-fabric.git
cd zhc-fabric
./scripts/test.sh
```

Layout:

```text
zhc-fabric/
├── plugin.yaml / after-install.md / __init__.py
├── client.py / config.py / schemas.py
├── sidecar.env.example
├── skill/SKILL.md
├── scripts/          setup, install-sidecar (Docker OTP), smoke, test
├── sidecar/otp/      **Primary** Erlang/OTP + Dockerfile
├── sidecar/docker-compose.yml
├── sidecar/stub/     Python fallback / contract-test helper
├── tests/            pytest (mock OpenAI; can target OTP via FABRIC_TEST_URL)
└── docs/             BUILD, API, plugin contract, portability
```

Contributions: keep the plugin **fail-open**, Docker OTP as default install path, and preserve the `/v1` JSON contract.

---

## Build log

A technical account of how v0.1.0 was actually built: the shape of the thing, the
walls we hit, and what the fix was. Design rationale lives in
[docs/BUILD.md](./docs/BUILD.md); this is the construction record.

### The premise

The bet was narrow and worth stating up front, because it constrained every later
decision: **inference speed is a solved problem, orchestration isn't.** llama.cpp,
Ollama and vLLM already win the tokens/sec fight. What hurts is the layer above —
"ask three minds, let them argue, give me one answer" — where a Python agent
process ends up running short-lived LLM calls through thread pools, coupling
committee reliability to chat reliability.

So: put the committee in Erlang/OTP (actors, supervision, leases), hide it behind a
boring HTTP contract, and keep Hermes a thin client that fails open. Two rules fell
out of that and never moved:

1. **No Hermes fork.** Plugin + HTTP only, so `hermes update` can't break us.
2. **The contract is the product boundary.** Runtime swaps behind `/v1`; the plugin
   never notices.

### Phases, as built

| Phase | Shipped | Notes |
|-------|---------|-------|
| **0 — Scaffold + contract** | Plugin skeleton, docs, `plugin.yaml`, healthcheck | Contract written *before* either runtime existed |
| **1 — Python stub sidecar** | `/health`, `/v1/consensus`, `/v1/fanout`, `/v1/metrics`; majority policy; global lease | Stdlib only. Existed to prove the API, not to ship |
| **2 — Packaging** | `install-sidecar.sh`, smoke + offline suites, compose | "Clean machine" install made reproducible |
| **3 — Erlang/OTP fabric** | OTP 27 app, supervision tree, monitor-based lease, job-per-process | **The actual product.** Same contract, zero plugin changes |
| **4a — `love_eq` + metrics** | Real LLM rubric scorer in both runtimes, JSON counters | Live-verified against a real model |
| **4b+ — multi-node** | ✗ **Deliberately dropped** | See [Cap decision](#the-cap-decision) |

Writing the contract first (Phase 0) is what made Phase 3 boring. The OTP runtime
landed behind the *same* `/v1` API the Python stub had been serving for two phases,
and the plugin needed no tool-schema change at all.

### What broke, and what fixed it

#### 1. The lease didn't actually lease (Python stub)

**Symptom:** `MAX_INFLIGHT_COMPLETIONS` was enforced per job, not globally. Three
concurrent consensus jobs at `n=3` each happily opened nine outbound completions and
stampeded a single-consumer GPU — the exact failure the lease existed to prevent.

**Cause:** the original `_acquire_slots` reasoned about slots inside job scope. Job
isolation was doing the opposite of what a *global* cap needs.

**Fix:** one module-level semaphore, acquired per **outbound completion** rather
than per job:

```python
# Global lease: every outbound completion must hold a slot, across all jobs.
_slots = threading.Semaphore(MAX_INFLIGHT)
```

**Lesson that carried into OTP:** the lease has to live at the resource, not at the
caller. There's one GPU; there should be exactly one thing counting.

#### 2. A semaphore is the wrong primitive when workers can crash (OTP)

**Symptom:** porting the semaphore idea to Erlang reintroduced a classic leak. A
vote worker that dies mid-completion (model timeout, malformed response, kill)
never runs its release path. Slots bleed away until the fabric wedges at zero
capacity — and it stays wedged, because nothing is left to notice.

**Fix:** make the lease a `gen_server` that **monitors every holder**. The VM
reports the death; the lease reclaims the slot. No cleanup code in the worker, no
try/after discipline to forget:

```erlang
handle_info({'DOWN', _MRef, process, Pid, _Reason}, #{holders := H} = S) ->
    case maps:is_key(Pid, H) of
        true -> {noreply, grant_next(remove_holder(Pid, S))};
        false -> {noreply, S}
    end;
```

This is the whole argument for OTP in one function. The Python version can only
approximate it with wrappers that a crash can skip.

#### 3. The acquire-timeout race

**Symptom:** `gen_server:call(?MODULE, acquire, TimeoutMs)` can time out on the
caller side at the same instant the lease grants it a slot. The caller walks away
believing it got nothing; the lease believes a slot is held. Slot lost, permanently.

**Fix:** timing out isn't a passive event — the caller must explicitly retract:

```erlang
acquire(TimeoutMs) ->
    try gen_server:call(?MODULE, acquire, TimeoutMs)
    catch
        exit:{timeout, _} ->
            %% May have been granted concurrently with our timeout; cancel
            %% removes us from the queue or releases the racing grant.
            gen_server:cast(?MODULE, {cancel, self()}),
            busy
    end.
```

`{cancel, Pid}` handles both worlds — still queued (drop from queue) or already
granted (release it) — because the caller genuinely cannot know which it is.

#### 4. Two runtimes, one contract, guaranteed drift

**Symptom:** with a Python stub *and* an OTP app both serving `/v1`, every change
had two homes. They were already diverging on error shapes and `n` clamping.

**Fix:** refused to write two test suites. One contract suite points at whatever is
listening:

```bash
./scripts/test.sh                                   # mock OpenAI, no GPU
FABRIC_TEST_URL=http://127.0.0.1:7733 ./scripts/test.sh   # the real OTP container
```

Same checks (`check_health`, `check_consensus_majority`, `check_fanout`,
`check_error_paths`, `check_love_eq_rubric`, `check_n_clamped`) run against both.
Anywhere the assertions couldn't be shared was a place the runtimes had drifted —
the suite doubled as a drift detector.

We even made a prompt an assertion: the `love_eq` scorer system prompt must contain
the token `love-equation-scorer` unless the caller overrides the rubric, so both
runtimes are provably invoking the same contract.

#### 5. `127.0.0.1` means something different inside a container

**Symptom:** the highest-frequency install failure, and an unhelpful one. Users
configure `http://127.0.0.1:11434/v1` — correct on the host, correct in every
Ollama doc. Inside the container it points at *the container*, so the fabric
reports connection refused against a model that is plainly running.

**Fix:** stop expecting users to think in namespaces. Rewrite at start, and give the
container a route home:

```bash
# Models on the host: container cannot use 127.0.0.1 (that is the container itself).
dockerize_base_url() {
  local u="$1"
  u="${u//127.0.0.1/host.docker.internal}"
  u="${u//localhost/host.docker.internal}"
  printf '%s' "$u"
}
```

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

The user keeps writing the host URL that matches their own reality. Translation is
our job, and the rewrite is announced at start so it isn't spooky.

#### 6. Erlang was the right runtime and the wrong ask

**Symptom:** the honest install story was briefly "install Erlang, install rebar3,
build the app." For a plugin whose pitch is *lower orchestration friction*, that's
self-defeating — most people would bounce there and never see the fabric.

**Fix:** make Docker the **only** supported OTP path, and keep OTP entirely inside
the image:

```dockerfile
FROM erlang:27-alpine
COPY src/ src/
RUN mkdir -p ebin \
 && erlc -o ebin src/*.erl \
 && cp src/zhc_fabric.app.src ebin/zhc_fabric.app
```

Stdlib only — `inets` httpd, `httpc`, `json`. **Zero hex dependencies, no rebar3,
`erlc` alone.** That was a deliberate constraint, not an accident: no dependency
resolver in the image means no dependency resolver in anyone's install failure.

The rule we wrote down and held to:

> If install "hits a wall," it should be **install Docker**, never **install Erlang**.

Erlang remains the reason the thing works. It just stopped being the user's problem.

#### 7. The installer interrogated people who hadn't decided yet

**Symptom:** `requires_env` in `plugin.yaml` made `hermes plugins install` demand a
base URL, model and API key up front — before the user had read a line of docs or
knew what a "model endpoint" meant here. Worst possible moment to ask.

**Fix:** dropped `requires_env` entirely. Install just installs. Configuration is a
separate, explicit step with two doors:

```bash
scripts/setup.sh --wizard   # interactive prompts
scripts/setup.sh --manual   # prints exact files + vars, touches nothing
```

`--manual` exists because scripted/config-managed users find wizards hostile: it
tells you what to edit and gets out of the way.

#### 8. The Hermes plugin contract fights pytest

**Symptom:** collection errors on `python3 -m pytest tests/` — cryptic
`import_module('__init__')` failures.

**Cause:** Hermes requires `register()` in a root `__init__.py`, which makes the repo
root a package, which makes pytest's rootdir collection import `__init__` as a
top-level module. Two valid conventions, one directory, no winner.

**Fix:** not worth restructuring the repo over. Pin the invocation and document the
why at the point of pain:

```bash
# Repo root has __init__.py (Hermes plugin contract), which breaks pytest
# collection from the root — so run from tests/.
cd "$(dirname "$0")/../tests"
exec pytest -q --import-mode=importlib "$@" .
```

`./scripts/test.sh` is the supported entry point. Running bare `pytest` from the
root still fails, by design and with a comment explaining it.

#### 9. `love_eq` was a stub wearing a policy's name

**Symptom:** through Phases 1–3, `love_eq` was a length heuristic. It had a real
name in the API and no real scoring behind it — a documentation lie waiting to be
found.

**Fix (Phase 4a):** one real LLM rubric pass per job — temperature 0.2, lease-gated
like any other completion, strict JSON `[{id, C, D}]`, winner by `net = C − D`. The
rubric is configurable: request `rubric` field > `FABRIC_LOVE_EQ_RUBRIC` env >
built-in default.

**The constraint that shaped it:** a scorer failure must never fail the job. A
committee that already produced good votes shouldn't 500 because the judge choked
on JSON:

```erlang
%% One LLM rubric pass scoring every vote; falls back to the length
%% heuristic on any failure. Never fails the job.
love_eq_scores(Prompt, Votes, Endpoints, TimeoutMs, Rubric) ->
    case llm_scores(Prompt, Votes, Endpoints, TimeoutMs, Rubric) of
        {ok, Scores} -> Scores;
        {error, Reason} ->
            Note = <<"heuristic fallback: ", Reason/binary>>,
            [heuristic_score(V, Note) || V <- Votes]
    end.
```

The degraded path is **labelled**, not silent — results carry
`heuristic fallback: <reason>`, so you can always tell a real rubric score from a
fallback. Same fail-open instinct as the plugin, one layer down.

Live-verified on a real model: the critic vote won at net 8.0.

#### 10. Docs drifted the moment the default changed

**Symptom:** flipping Docker from *optional* to *primary* (`fd69650`) updated the
README. `docs/BUILD.md`, `docs/PORTABILITY.md` and `skill/SKILL.md` kept telling
people Docker was optional and Python was the default — actively steering users onto
the fallback path.

**Fix:** a dedicated sweep (`ea7b6d6`) to make secondary docs match the primary
decision. Noting it here because it's the failure mode that keeps recurring: a
default that changes in one file and stays changed in exactly one file. The install
path is documented in more places than it is implemented.

### The cap decision

Multi-node Erlang distribution across a LAN was in the plan from day one. It's the
most interesting thing left, it's the natural payoff of choosing OTP, and it is
**not in this release.**

Cutting it was the right call. Single-node with a *real* `love_eq` beats multi-node
with a stubbed one. The distribution work was half-built, unbenchmarked, and would
have held the shippable single-node fabric hostage to a feature nobody had asked
for yet.

> **Cap decision (2026-07-16):** Project is complete at Phase 4a. Do not start
> multi-node distribution until deliberately reopened.

Written into [docs/BUILD.md](./docs/BUILD.md) so it's a decision, not a lapse.

### What we'd tell the next implementer

| Principle | Where it paid off |
|-----------|-------------------|
| **Contract before runtime** | OTP replaced Python behind `/v1` with zero plugin changes |
| **One test suite, many runtimes** | `FABRIC_TEST_URL` caught every drift between stub and OTP |
| **Fail open, everywhere** | `register()` never raises; a dead sidecar never breaks chat; a dead scorer never fails a job |
| **Put the lease at the resource** | One GPU → exactly one thing counting, monitor-backed |
| **Make the failure "install Docker"** | The runtime's requirements are the maintainer's problem, not the user's |
| **Label degraded output** | `heuristic fallback: <reason>` beats a silently worse answer |
| **Cap the scope in writing** | A dropped feature in a decision log isn't debt; unwritten it's a lie |

### Verification status (honest)

| Check | Status |
|-------|--------|
| Offline contract suite (`./scripts/test.sh`) | ✅ 3 passed, mock OpenAI, no GPU needed |
| Same suite vs OTP container (`FABRIC_TEST_URL`) | ✅ Passes — identical contract |
| `love_eq` real rubric, live model | ✅ Verified on one host (critic won, net 8.0) |
| Fail-open with sidecar down | ✅ Tools return `success: false`; Hermes chats normally |
| Multi-host / multi-OS install | ⚠️ Not verified — `host.docker.internal` is the likeliest first break |
| Sustained load / stampede benchmarks | ⚠️ Not measured — lease is correct-by-construction, not yet proven under load |

The suite is a **contract** suite, not a coverage suite. It pins the API shape and
the runtime parity — those are the things that would silently break. It does not
claim broad line coverage of either runtime.

---

## Docs & license

| Doc | Contents |
|-----|----------|
| [docs/BUILD.md](./docs/BUILD.md) | Design, phases, acceptance criteria |
| [docs/PLUGIN-CONTRACT.md](./docs/PLUGIN-CONTRACT.md) | Hermes plugin surface |
| [docs/SIDECAR-API.md](./docs/SIDECAR-API.md) | Full HTTP contract |
| [docs/PORTABILITY.md](./docs/PORTABILITY.md) | Any-install rules |
| [sidecar/otp/README.md](./sidecar/otp/README.md) | OTP Docker runtime |
| [CHANGELOG.md](./CHANGELOG.md) | Release notes |
| [after-install.md](./after-install.md) | Shown after `hermes plugins install` |

**License:** MIT — see [LICENSE](./LICENSE).

**Maintainers:** zhc-fabric · RealAndWorks garage lab · GitHub: [RegardV/zhc-fabric](https://github.com/RegardV/zhc-fabric)
