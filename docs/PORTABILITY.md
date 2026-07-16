# Portability — Sidecar Any Hermes Install

Goal: **zhc-fabric** works on a stranger’s machine with a stock Hermes install, without assuming RealAndWorks garage lab paths or a forked agent.

---

## 1. What “any install” means

| Dimension | Portable behavior |
|-----------|-------------------|
| OS | Linux first; macOS Docker path; Windows via WSL2 or native when Hermes supports plugins there |
| Hermes location | `$HERMES_HOME` or `~/.hermes` — never hardcode `/home/regard/...` |
| Inference | User-supplied OpenAI-compatible `base_url` + `model` |
| GPU | Optional; fabric runs even if models are remote |
| **Docker** | **Required** for the product path (OTP fabric image) |
| Erlang on host | **Not required** — image is `erlang:27-alpine`; OTP stays in the container |
| Network | Localhost default; LAN optional |

---

## 2. Forbidden assumptions

Do **not** bake in:

- `~/qwen-qwopus`, `:8080` MTP flags, or host-specific nginx
- `~/zhc-os` paths or InkyPyrus-only souls
- Composio / Bitwarden keys from a personal `.env`
- Requirement that Ollama is installed
- Requirement that users install **Erlang/rebar/hex** on the host
- Patches to `~/.hermes/hermes-agent/**`

**Do** require Docker for the supported sidecar path (document clearly; fail with install-Docker guidance, not install-Erlang).

---

## 3. Allowed discovery

| Input | OK |
|-------|----|
| `HERMES_HOME` | Yes |
| `ZHC_FABRIC_*` env | Yes |
| `$HERMES_HOME/config.yaml` `custom_providers` (optional enhancement) | Yes, if parse fails → ignore |
| `$HERMES_HOME/zhc-fabric/config.json` | Yes |
| `plugin.yaml` / package relative paths via `Path(__file__).parent` | Yes |

Optional nicety (not required for MVP): read Hermes `custom_providers` to suggest endpoints in skill text or default fan-out — must degrade if YAML missing/malformed.

---

## 4. Install paths matrix

| Method | Command / action | Works offline? |
|--------|------------------|----------------|
| Git | `hermes plugins install org/zhc-fabric --enable` | Needs network once |
| Local copy | `cp -a . ~/.hermes/plugins/zhc-fabric` | Yes |
| Symlink (dev) | `ln -s ~/projects/zhc-fabric ~/.hermes/plugins/zhc-fabric` | Yes |
| Project plugin | `.hermes/plugins/` + `HERMES_ENABLE_PROJECT_PLUGINS=true` | Yes |
| pip entry point | future | Depends |

Always:

```yaml
plugins:
  enabled:
    - zhc-fabric
```

---

## 5. Sidecar runtime matrix

| Runtime | Role |
|---------|------|
| **Docker OTP** (`sidecar/otp`) | **Primary product** — actors, supervision, leases |
| Python stub (`FABRIC_RUNTIME=python`) | Dev / offline tests only — not the install default |

`scripts/install-sidecar.sh` behavior:

1. Default `FABRIC_RUNTIME=otp`: require Docker → `docker compose up --build`  
2. If Docker missing: exit non-zero with “install Docker; you do not need host Erlang”  
3. Only if `FABRIC_RUNTIME=python`: run `sidecar/stub/server.py`  
4. Rewrite `127.0.0.1` / `localhost` model URLs to `host.docker.internal` for the container

---

## 6. Fail-open matrix

| Situation | Hermes | Plugin tools |
|-----------|--------|--------------|
| Plugin disabled | Normal | Tools absent |
| Plugin enabled, sidecar down | Normal | `success: false` |
| Sidecar up, no DEFAULT_BASE_URL, request has endpoints | Normal | Works |
| Sidecar up, no endpoints anywhere | Normal | Clear error JSON |
| Inference timeout | Normal | Vote errors / job error |
| Plugin `register()` exception | **Must not happen** | Guard all init |

---

## 7. Port and process clash checklist

| Port | Common owner | Fabric action |
|------|--------------|---------------|
| 7733 | (fabric default) | Configurable via `FABRIC_PORT` / URL |
| 8000 / 8080 | llama.cpp / proxies | Client only; do not bind |
| 11434 | Ollama | Client only |
| 9123 | Hermes dashboard | Do not bind |
| 8790 | hermes-hudui | Do not bind |

---

## 8. Fresh-machine acceptance test

Run on a machine that is **not** the garage lab profile:

1. Install Hermes via official installer.
2. Point Hermes at any OpenAI-compatible model (even cloud).
3. Install zhc-fabric plugin; enable.
4. Start sidecar with `DEFAULT_BASE_URL` / `DEFAULT_MODEL` set.
5. CLI: ask agent to run `fabric_status` then a tiny `fabric_consensus`.
6. Stop sidecar; confirm chat still works and tools error cleanly.
7. Run `hermes update`; re-open session; plugin still loads.

If step 7 fails, treat as **release blocker**.

---

## 9. Documentation obligations for each release

- [ ] README one-liners for install / start / health  
- [ ] Env table  
- [ ] API examples with `curl`  
- [ ] Explicit “not a Hermes fork”  
- [ ] Explicit “does not speed up GPU kernels”  
- [ ] Changelog: plugin version + API version + sidecar runtime  

---

## 10. Distribution checklist (open source)

- [ ] Public git repo with LICENSE  
- [ ] No secrets in history  
- [ ] Reproducible Docker build  
- [ ] Tag releases (`v0.1.0`) matching `plugin.yaml` version  
- [ ] Issue template: Hermes version, OS, sidecar runtime, `/health` output  
- [ ] Security: report path for abuse of open LAN bind  

---

## 11. Why this shape is portable

```text
Hermes stable extension API  →  plugin (adapter)
Independent process           →  sidecar (implementation)
Industry LLM HTTP shape       →  OpenAI-compatible backends
```

Three loose couplings mean any one layer can change without rewriting the others. That is the definition of “sidecar any installation.”
