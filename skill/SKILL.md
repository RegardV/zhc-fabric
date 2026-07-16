# ZHC Fabric — multi-view consensus

## When to use

Use the fabric tools for:

- High-stakes decisions (architecture, security, money, public statements)
- Design tradeoffs where dissent is valuable
- Risk review / “what could go wrong”
- When the user asks for consensus, a committee, multi-model vote, or Love Equation framing

## When NOT to use

- Simple facts or single-file lookups
- Latency-sensitive chitchat
- Tasks that need tools (shell, browser) — fabric only does LLM fan-out
- When `fabric_status` shows the sidecar is down (reason normally; do not invent a committee)

## Tools

1. **`fabric_status`** — health of the sidecar (default `http://127.0.0.1:7733`).
2. **`fabric_consensus`** — N parallel views + reduce (`policy`: `majority` | `love_eq` | `unanimous_soft`).
3. **`fabric_fanout`** — N raw views without reduce (debugging / present dissent).

## How to present results

- Lead with the final `answer`.
- Summarize meaningful dissent from `votes[]` honestly.
- If `ok`/`success` is false, report `error` and continue with single-model reasoning.

## Slash command

`/fabric status` · `/fabric start` · `/fabric url`
