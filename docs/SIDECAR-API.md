# Sidecar HTTP API — zhc-fabric

Stable contract between **any client** (Hermes plugin first) and the **fabric sidecar**.

- Version prefix: `/v1`
- Default bind: `127.0.0.1:7733`
- Content-Type: `application/json; charset=utf-8`
- Errors: always JSON body, never bare HTML

---

## 1. Versioning

| Rule | Detail |
|------|--------|
| Breaking changes | New path prefix `/v2` or new field with migration note |
| Additive fields | Allowed on responses without bump |
| Plugin compatibility | Plugin 0.x speaks `/v1` only |

`GET /health` includes `"api": "v1"`.

---

## 2. Endpoints

### 2.1 `GET /health`

Liveness and light readiness.

**Response 200:**

```json
{
  "ok": true,
  "api": "v1",
  "version": "0.1.0",
  "runtime": "stub-python | otp",
  "inflight": 0,
  "max_inflight": 2,
  "uptime_s": 123
}
```

**Response when overloaded (still 200 or 503):**

```json
{
  "ok": true,
  "api": "v1",
  "version": "0.1.0",
  "inflight": 2,
  "max_inflight": 2,
  "degraded": true
}
```

If process is up but cannot accept work, prefer `ok: true` with `degraded: true` so the plugin distinguishes “dead” vs “busy”.

Connection refused → client-side failure (plugin maps to `success: false`).

---

### 2.2 `POST /v1/consensus`

Fan-out multiple completions, then reduce to one answer.

**Request:**

```json
{
  "prompt": "string, required",
  "n": 3,
  "policy": "majority",
  "timeout_ms": 120000,
  "system_prompt": "optional",
  "temperature": 0.6,
  "endpoints": [
    {
      "name": "optional-label",
      "base_url": "http://127.0.0.1:8000/v1",
      "model": "qwopus-3.6",
      "api_key": ""
    }
  ],
  "metadata": {
    "session_id": "optional opaque",
    "source": "hermes"
  }
}
```

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `prompt` | string | — | Required, non-empty |
| `n` | int | 3 | Clamped to `1..8` (configurable hard max) |
| `policy` | string | `majority` | See policies |
| `timeout_ms` | int | 120000 | Wall clock for whole job |
| `system_prompt` | string | built-in | Applied to proposers |
| `temperature` | number | server default | Passed to backend if supported |
| `endpoints` | array | env defaults | Round-robin or parallel assignment |
| `metadata` | object | `{}` | Logged only; not sent to models |

**Response 200 (success):**

```json
{
  "ok": true,
  "answer": "final synthesized or chosen text",
  "policy": "majority",
  "votes": [
    {
      "id": "v0",
      "role": "proposer",
      "model": "qwopus-3.6",
      "endpoint": "local-a",
      "text": "…",
      "latency_ms": 1500,
      "error": null
    },
    {
      "id": "v1",
      "role": "critic",
      "model": "qwopus-3.6",
      "endpoint": "local-a",
      "text": "…",
      "latency_ms": 1600,
      "error": null
    }
  ],
  "scores": null,
  "elapsed_ms": 4120,
  "error": null
}
```

**Response 200 (logical failure):**

Prefer HTTP 200 with `ok: false` so the plugin always parses JSON:

```json
{
  "ok": false,
  "answer": null,
  "policy": "majority",
  "votes": [],
  "elapsed_ms": 12,
  "error": "all endpoints failed: connection refused"
}
```

**HTTP 4xx/5xx:** allowed for malformed JSON / auth (if added later). Plugin still tries to parse body.

---

### 2.3 `POST /v1/fanout`

Same request shape as consensus (ignore `policy` or accept and no-op).

**Response:**

```json
{
  "ok": true,
  "votes": [ /* same vote objects */ ],
  "elapsed_ms": 3000,
  "error": null
}
```

No `answer` field required.

---

### 2.4 `GET /v1/metrics` (optional)

```json
{
  "ok": true,
  "jobs_total": 10,
  "jobs_ok": 9,
  "jobs_err": 1,
  "avg_elapsed_ms": 5000,
  "inflight": 1
}
```

---

## 3. Policies

| `policy` | Reduce behavior |
|----------|-----------------|
| `majority` | Prefer agreement; if split, run a **judge** completion over the votes or pick highest-overlap text |
| `love_eq` | Score each vote with rubric (C vs D); pick max net; include `scores` array |
| `unanimous_soft` | If all similar → that answer; else return compromise + note dissent in `answer` |

Unknown policy → `ok: false`, `error: "unknown policy"`, or fallback to `majority` with `warning` field (pick one and document in code; recommend hard fail for predictability).

---

## 4. Endpoint resolution

1. If request `endpoints` non-empty → use them (may repeat one URL for all `n` actors).
2. Else if env `DEFAULT_BASE_URL` + `DEFAULT_MODEL` set → synthesize one endpoint, reuse for all actors.
3. Else → `ok: false`, `error: "no endpoints configured"`.

**OpenAI-compatible call shape** (sidecar → model server):

```http
POST {base_url}/chat/completions
Content-Type: application/json
Authorization: Bearer {api_key}   # omit if empty

{
  "model": "{model}",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "temperature": 0.6
}
```

Parse `choices[0].message.content`. On failure, vote entry has `error` string and empty `text`.

---

## 5. Concurrency and limits

| Limit | Default | Enforcement |
|-------|---------|-------------|
| `n` max | 8 | Clamp or reject |
| Prompt max chars | 100_000 | Reject |
| Global inflight LLM calls | 2 | Queue or 503/degraded |
| Per-job timeout | `timeout_ms` | Cancel outstanding work best-effort |

---

## 6. Security notes

- Default bind **localhost only**.
- If binding `0.0.0.0`, document LAN trust model; no auth in MVP (optional shared token header later: `X-Fabric-Token`).
- Do not log full prompts at info level in production builds (debug only).
- Treat model outputs as untrusted when returning to Hermes.

---

## 7. CORS

Not required for server-side Hermes plugin. If a future web UI calls fabric, add explicit CORS config — off by default.

---

## 8. Example curl

```bash
curl -sS http://127.0.0.1:7733/health | jq .

curl -sS http://127.0.0.1:7733/v1/consensus \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "Name three risks of multi-agent consensus on one GPU.",
    "n": 3,
    "policy": "majority",
    "endpoints": [{
      "base_url": "http://127.0.0.1:8000/v1",
      "model": "qwopus-3.6",
      "api_key": ""
    }]
  }' | jq .
```

---

## 9. Compatibility with non-Hermes clients

Any language can call this API. Examples:

- Grok / Claude Code orchestration scripts
- ZHC-OS CTO batch jobs
- CI “debate this design” step

The Hermes plugin is a **client**, not the only client.
