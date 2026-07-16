# Hermes Plugin Contract — zhc-fabric

This document specifies how the **zhc-fabric** plugin attaches to Hermes without modifying core.

Hermes version baseline: any install with general plugins (`PluginManager`, `register(ctx)`, `plugins.enabled` allow-list). Verified against local Hermes Agent **0.18.x** docs/patterns.

---

## 1. Discovery and enablement

| Source | Path |
|--------|------|
| User plugins | `$HERMES_HOME/plugins/zhc-fabric/` (default `~/.hermes/plugins/zhc-fabric/`) |
| Project plugins | `./.hermes/plugins/zhc-fabric/` (needs `HERMES_ENABLE_PROJECT_PLUGINS=true`) |
| Git install | `hermes plugins install <owner>/<repo> [--enable]` |
| pip (optional later) | entry point group `hermes_agent.plugins` |

**Opt-in:**

```yaml
# $HERMES_HOME/config.yaml
plugins:
  enabled:
    - zhc-fabric
```

```bash
hermes plugins enable zhc-fabric
hermes plugins list
```

Gateway / CLI must reload plugins after install (restart gateway or new session).

---

## 2. Manifest (`plugin.yaml`)

```yaml
name: zhc-fabric
version: "0.1.0"
description: >
  Sidecar multi-model consensus fabric. Parallel propose/critique/vote via
  an external service (default http://127.0.0.1:7733). Does not modify Hermes core.
author: zhc-fabric / RealAndWorks garage lab
provides_tools:
  - fabric_status
  - fabric_consensus
  - fabric_fanout
provides_hooks:
  - on_session_start
provides_commands:
  - fabric
# requires_env: []   # keep empty for local-first installs
```

Rules:

- `name` **must** match directory name and `plugins.enabled` entry: `zhc-fabric`.
- Do **not** set tool names that collide with Hermes built-ins.
- Do **not** use `override=True` on built-in tools.

---

## 3. Entry point

Hermes loads `__init__.py` and calls:

```python
def register(ctx: PluginContext) -> None:
    ...
```

Requirements:

1. **Never raise** out of `register()` for missing sidecar, missing Docker, or network errors.
2. Log warnings with logger name `zhc-fabric` / `zhc_fabric`.
3. Accept forward-compatible `**kwargs` on all handlers and hooks.
4. Tool handlers return **JSON strings** always (success and failure).

---

## 4. Tools

### 4.1 `fabric_status`

| Field | Value |
|-------|--------|
| toolset | `zhc_fabric` |
| parameters | none required |
| behavior | GET `{base}/health` |
| success JSON | `{"success": true, "ok": true, "version": "...", ...}` |
| failure JSON | `{"success": false, "ok": false, "error": "..."}` |

### 4.2 `fabric_consensus`

| Field | Value |
|-------|--------|
| toolset | `zhc_fabric` |
| required | `prompt` (string) |
| optional | `n` (int, default 3, max 8), `policy` (string), `timeout_s` (int) |
| behavior | POST `{base}/v1/consensus` |
| description (LLM-facing) | Must state: use for high-stakes decisions / multi-view review; not for trivial Q&A |

Handler sketch:

```python
def fabric_consensus(params, **kwargs) -> str:
    prompt = (params.get("prompt") or "").strip()
    if not prompt:
        return json.dumps({"success": False, "error": "prompt required"})
    # call client; map ok → success
    return json.dumps({...})
```

### 4.3 `fabric_fanout` (MVP+ optional)

Same as consensus but POST `/v1/fanout` — returns votes without reduce. Useful for debugging.

---

## 5. Slash command

```python
ctx.register_command("fabric", handler, description="ZHC fabric status/start help")
```

| Input | Behavior |
|-------|----------|
| `/fabric` or `/fabric status` | Health JSON |
| `/fabric start` | Best-effort auto-start script if allowed |
| other | Usage string |

Gateway and CLI both surface `/fabric` once plugin is enabled.

---

## 6. Skill

```python
ctx.register_skill("zhc-fabric", path_to_SKILL_md)
```

Skill content should tell the agent:

- When to call `fabric_consensus` (architecture tradeoffs, policy, risk, multi-stakeholder)
- When **not** to (simple facts, single-tool lookups, latency-sensitive chitchat)
- How to read `votes[]` and present dissent honestly
- That offline fabric means fall back to normal single-model reasoning

Namespace: Hermes may expose as `plugin:zhc-fabric` / `skill_view` depending on version — follow current Hermes skill plugin docs.

---

## 7. Hooks

| Hook | Use |
|------|-----|
| `on_session_start` | Optional: debug log if health fails; **do not** inject noisy context every session |
| `pre_llm_call` | **Not recommended** for MVP (don’t force fabric on every turn) |

---

## 8. CLI subcommands (optional)

```python
ctx.register_cli_command(
    name="fabric",
    help="Manage ZHC consensus fabric sidecar",
    setup_fn=...,
    handler_fn=...,
)
```

Target UX:

```bash
hermes fabric status
hermes fabric start
hermes fabric stop
```

Phase 2+; slash command is enough for MVP.

---

## 9. Config helpers

```python
# config.py responsibilities
hermes_home() -> Path      # HERMES_HOME or ~/.hermes
fabric_url() -> str        # env → config.json → default
state_dir() -> Path        # hermes_home() / "zhc-fabric"
```

Plugin may create `$HERMES_HOME/zhc-fabric/` for local state (not secrets).

---

## 10. Client rules

File: `client.py`

- stdlib only: `urllib.request`, `json`
- Timeouts always set
- Catch `URLError`, timeout, `JSONDecodeError` → structured dict, never raise to Hermes loop
- No retries that amplify GPU load (at most one retry on pure connect failure, optional)

---

## 11. Toolset visibility

If Hermes filters toolsets by platform (CLI vs Telegram), ensure `zhc_fabric` is available where consensus is useful. Prefer default registration so all sessions see the tools unless user disables the plugin.

Do not put tools only under a niche toolset that is never enabled.

---

## 12. Compatibility matrix

| Hermes capability | Required for MVP |
|-------------------|------------------|
| `ctx.register_tool` | Yes |
| `ctx.register_hook` | Optional |
| `ctx.register_command` | Recommended |
| `ctx.register_skill` | Recommended |
| `ctx.register_cli_command` | Later |
| `ctx.llm.complete` | No (sidecar owns multi-call) |
| Model provider plugins | No |
| Memory provider plugins | No |

If an older Hermes lacks `register_skill`, plugin should try/except and still register tools.

---

## 13. Anti-patterns

- Reading `~/.hermes/hermes-agent` internals or monkeypatching
- Spawning long-lived threads inside the plugin for consensus (that is the sidecar’s job)
- Shelling out to `curl` for the hot path (use `client.py`)
- Storing API keys in `plugin.yaml`
- Naming tools `delegate_task`, `terminal`, `web_search`, etc.

---

## 14. Manual verification checklist

1. `hermes plugins enable zhc-fabric`
2. Restart gateway / open new CLI
3. Ask model to call `fabric_status` (sidecar down) → clear error JSON
4. Start sidecar → `fabric_status` ok
5. `fabric_consensus` with short prompt → structured answer
6. Disable plugin → tools gone; Hermes healthy
