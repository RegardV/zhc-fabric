#!/usr/bin/env python3
"""zhc-fabric Phase-1 Python sidecar: /health, /v1/consensus, /v1/fanout.

Stdlib only. OpenAI-compatible chat.completions fan-out with concurrency lease.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import traceback
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse

VERSION = "0.1.0"
API = "v1"
START_TS = time.time()

HOST = os.environ.get("FABRIC_HOST", "127.0.0.1")
PORT = int(os.environ.get("FABRIC_PORT", "7733"))
DEFAULT_BASE_URL = os.environ.get("DEFAULT_BASE_URL", "").rstrip("/")
DEFAULT_MODEL = os.environ.get("DEFAULT_MODEL", "")
DEFAULT_API_KEY = os.environ.get("DEFAULT_API_KEY", "")
MAX_INFLIGHT = max(1, int(os.environ.get("MAX_INFLIGHT_COMPLETIONS", "2")))
MAX_N = max(1, min(16, int(os.environ.get("FABRIC_MAX_N", "8"))))
MAX_PROMPT_CHARS = int(os.environ.get("FABRIC_MAX_PROMPT_CHARS", "100000"))
LOVE_EQ_RUBRIC = os.environ.get("FABRIC_LOVE_EQ_RUBRIC", "").strip()

# "love-equation-scorer" token is contract: test mocks key on it.
DEFAULT_LOVE_EQ_RUBRIC = (
    "You are the love-equation-scorer for a multi-agent committee. "
    "Score each vote: C = cooperation/creation value 0-10, "
    "D = damage/deception risk 0-10. Reply with ONLY a JSON array like "
    '[{"id":"v0","C":7,"D":1}] — no prose, no code fences.'
)

_inflight = 0
_inflight_lock = threading.Lock()
# Global lease: every outbound completion must hold a slot, across all jobs.
_slots = threading.Semaphore(MAX_INFLIGHT)
_stats_lock = threading.Lock()
_stats = {"jobs_total": 0, "jobs_ok": 0, "jobs_err": 0, "elapsed_sum_ms": 0}


def _json_response(handler: BaseHTTPRequestHandler, code: int, body: dict[str, Any]) -> None:
    raw = json.dumps(body).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.end_headers()
    handler.wfile.write(raw)


def _read_json(handler: BaseHTTPRequestHandler) -> dict[str, Any] | None:
    length = int(handler.headers.get("Content-Length") or 0)
    if length <= 0:
        return {}
    if length > 2_000_000:
        return None
    raw = handler.rfile.read(length)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _track_start() -> None:
    global _inflight
    with _inflight_lock:
        _inflight += 1


def _track_end() -> None:
    global _inflight
    with _inflight_lock:
        _inflight = max(0, _inflight - 1)


def _health() -> dict[str, Any]:
    with _inflight_lock:
        inflight = _inflight
    return {
        "ok": True,
        "api": API,
        "version": VERSION,
        "runtime": "stub-python",
        "inflight": inflight,
        "max_inflight": MAX_INFLIGHT,
        "uptime_s": int(time.time() - START_TS),
        "degraded": inflight >= MAX_INFLIGHT,
        "default_base_url": DEFAULT_BASE_URL or None,
        "default_model": DEFAULT_MODEL or None,
    }


def _metrics() -> dict[str, Any]:
    with _stats_lock:
        total = _stats["jobs_total"]
        avg = (_stats["elapsed_sum_ms"] / total) if total else 0
        snap = dict(_stats)
    with _inflight_lock:
        inflight = _inflight
    return {
        "ok": True,
        "jobs_total": snap["jobs_total"],
        "jobs_ok": snap["jobs_ok"],
        "jobs_err": snap["jobs_err"],
        "avg_elapsed_ms": int(avg),
        "inflight": inflight,
    }


def _resolve_endpoints(body: dict[str, Any]) -> list[dict[str, str]] | str:
    eps = body.get("endpoints")
    if isinstance(eps, list) and eps:
        out: list[dict[str, str]] = []
        for i, e in enumerate(eps):
            if not isinstance(e, dict):
                continue
            base = str(e.get("base_url") or "").rstrip("/")
            model = str(e.get("model") or "")
            if not base or not model:
                continue
            out.append(
                {
                    "name": str(e.get("name") or f"ep{i}"),
                    "base_url": base,
                    "model": model,
                    "api_key": str(e.get("api_key") or ""),
                }
            )
        if out:
            return out
        return "endpoints provided but none valid (need base_url + model)"
    if DEFAULT_BASE_URL and DEFAULT_MODEL:
        return [
            {
                "name": "default",
                "base_url": DEFAULT_BASE_URL,
                "model": DEFAULT_MODEL,
                "api_key": DEFAULT_API_KEY,
            }
        ]
    return "no endpoints configured (set request.endpoints or DEFAULT_BASE_URL + DEFAULT_MODEL)"


def _chat_completion(
    endpoint: dict[str, str],
    messages: list[dict[str, str]],
    temperature: float,
    timeout_s: float,
) -> tuple[str | None, str | None, int]:
    """Returns (text, error, latency_ms)."""
    url = endpoint["base_url"].rstrip("/") + "/chat/completions"
    payload = {
        "model": endpoint["model"],
        "messages": messages,
        "temperature": temperature,
    }
    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    key = endpoint.get("api_key") or ""
    if key:
        headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    t0 = time.time()
    # ponytail: acquire wait + request can each take up to timeout_s (2x worst case);
    # split the budget if that ever matters.
    if not _slots.acquire(timeout=timeout_s):
        return None, "fabric busy: no free completion slot", int((time.time() - t0) * 1000)
    _track_start()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        latency = int((time.time() - t0) * 1000)
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            return None, "non-json completion response", latency
        choices = obj.get("choices") or []
        if not choices:
            return None, "no choices in completion response", latency
        msg = choices[0].get("message") or {}
        text = msg.get("content")
        if text is None:
            return None, "empty message content", latency
        return str(text).strip(), None, latency
    except Exception as e:  # noqa: BLE001
        latency = int((time.time() - t0) * 1000)
        return None, str(e), latency
    finally:
        _track_end()
        _slots.release()


def _role_for(i: int) -> str:
    if i == 0:
        return "proposer"
    if i == 1:
        return "critic"
    return "proposer"


def _system_for(role: str, custom: str | None) -> str:
    if custom:
        return custom
    if role == "critic":
        return (
            "You are a critical reviewer on a multi-agent committee. "
            "Identify weaknesses, risks, and missing considerations. "
            "Be concise and concrete. End with a clear recommendation."
        )
    return (
        "You are an independent member of a multi-agent committee. "
        "Give a clear, direct answer with brief reasoning. Be concise."
    )


def _fanout_votes(
    prompt: str,
    n: int,
    endpoints: list[dict[str, str]],
    system_prompt: str | None,
    temperature: float,
    timeout_ms: int,
) -> list[dict[str, Any]]:
    per_timeout = max(5.0, (timeout_ms / 1000.0) * 0.9)
    votes: list[dict[str, Any] | None] = [None] * n

    def work(i: int) -> dict[str, Any]:
        ep = endpoints[i % len(endpoints)]
        role = _role_for(i)
        user = prompt
        if role == "critic":
            user = (
                f"Critique and improve upon answers to the following.\n\n"
                f"QUESTION:\n{prompt}\n\n"
                f"Provide your own best answer after the critique."
            )
        messages = [
            {"role": "system", "content": _system_for(role, system_prompt)},
            {"role": "user", "content": user},
        ]
        text, err, latency = _chat_completion(ep, messages, temperature, per_timeout)
        return {
            "id": f"v{i}",
            "role": role,
            "model": ep["model"],
            "endpoint": ep["name"],
            "text": text or "",
            "latency_ms": latency,
            "error": err,
        }

    # Pool size capped by MAX_INFLIGHT so we don't stampede the GPU
    workers = min(n, MAX_INFLIGHT)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {pool.submit(work, i): i for i in range(n)}
        for fut in as_completed(futs):
            i = futs[fut]
            try:
                votes[i] = fut.result()
            except Exception as e:  # noqa: BLE001
                ep = endpoints[i % len(endpoints)]
                votes[i] = {
                    "id": f"v{i}",
                    "role": _role_for(i),
                    "model": ep["model"],
                    "endpoint": ep["name"],
                    "text": "",
                    "latency_ms": 0,
                    "error": str(e),
                }
    return [v for v in votes if v is not None]


def _normalize(text: str) -> str:
    t = text.lower().strip()
    t = re.sub(r"\s+", " ", t)
    return t


def _majority_pick(votes: list[dict[str, Any]]) -> str:
    good = [v for v in votes if v.get("text") and not v.get("error")]
    if not good:
        return ""
    # Prefer longest non-empty as crude quality; if two normalize equal, cluster
    buckets: dict[str, list[dict[str, Any]]] = {}
    for v in good:
        key = _normalize(v["text"])[:200]
        buckets.setdefault(key, []).append(v)
    best = max(buckets.values(), key=lambda vs: (len(vs), len(vs[0]["text"])))
    return best[0]["text"]


def _judge_reduce(
    prompt: str,
    votes: list[dict[str, Any]],
    endpoints: list[dict[str, str]],
    timeout_ms: int,
) -> str | None:
    good = [v for v in votes if v.get("text") and not v.get("error")]
    if not good:
        return None
    if len(good) == 1:
        return good[0]["text"]
    # If majority already clear via identical short answers, skip judge
    picked = _majority_pick(votes)
    norms = {_normalize(v["text"])[:120] for v in good}
    if len(norms) == 1:
        return picked

    parts = []
    for v in good:
        parts.append(f"### Vote {v['id']} ({v['role']})\n{v['text']}")
    judge_prompt = (
        f"You are the aggregator for a multi-agent committee.\n"
        f"Original question:\n{prompt}\n\n"
        f"Votes:\n\n" + "\n\n".join(parts) + "\n\n"
        f"Synthesize ONE clear final answer. Note dissent briefly if material. "
        f"Do not invent facts not present in the votes."
    )
    ep = endpoints[0]
    messages = [
        {
            "role": "system",
            "content": "You merge committee votes into a single decisive answer.",
        },
        {"role": "user", "content": judge_prompt},
    ]
    text, err, _ = _chat_completion(
        ep, messages, 0.3, max(10.0, (timeout_ms / 1000.0) * 0.4)
    )
    if err or not text:
        return picked
    return text


def _love_eq_scores(
    votes: list[dict[str, Any]], fallback_reason: str = "scorer unavailable"
) -> list[dict[str, Any]]:
    """Length-heuristic scores used only when the LLM rubric pass fails."""
    scores = []
    for v in votes:
        text = v.get("text") or ""
        c = min(10.0, 3.0 + len(text) / 200.0)  # crude "substance"
        d = 2.0 if any(
            w in text.lower() for w in ("delete all", "ignore safety", "harm users")
        ) else 0.5
        scores.append(
            {
                "id": v["id"],
                "C": round(c, 2),
                "D": round(d, 2),
                "net": round(c - d, 2),
                "note": f"heuristic fallback: {fallback_reason}",
            }
        )
    return scores


def _love_eq_llm_scores(
    prompt: str,
    votes: list[dict[str, Any]],
    endpoints: list[dict[str, str]],
    timeout_ms: int,
    rubric: str | None,
) -> tuple[list[dict[str, Any]] | None, str]:
    """One rubric completion scoring all votes. Returns (scores, reason-if-None)."""
    parts = [f"### Vote {v['id']} ({v['role']})\n{v['text']}" for v in votes]
    user = (
        f"Original question:\n{prompt}\n\n"
        f"Votes to score:\n\n" + "\n\n".join(parts)
    )
    messages = [
        {"role": "system", "content": rubric or DEFAULT_LOVE_EQ_RUBRIC},
        {"role": "user", "content": user},
    ]
    text, err, _ = _chat_completion(
        endpoints[0], messages, 0.2, max(10.0, (timeout_ms / 1000.0) * 0.4)
    )
    if err or not text:
        return None, err or "empty scorer reply"
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", t).strip()
    try:
        raw = json.loads(t)
    except json.JSONDecodeError:
        return None, "scorer reply not JSON"
    if not isinstance(raw, list):
        return None, "scorer reply not a JSON array"
    scores = []
    for entry in raw:
        if not isinstance(entry, dict):
            return None, "scorer entry not an object"
        try:
            c = float(entry["C"])
            d = float(entry["D"])
            vid = str(entry["id"])
        except (KeyError, TypeError, ValueError):
            return None, "scorer entry missing id/C/D"
        scores.append(
            {"id": vid, "C": round(c, 2), "D": round(d, 2), "net": round(c - d, 2), "note": "llm rubric"}
        )
    if not scores:
        return None, "scorer returned no entries"
    return scores, ""


def _run_job(body: dict[str, Any], reduce: bool) -> dict[str, Any]:
    t0 = time.time()
    prompt = (body.get("prompt") or "").strip()
    if not prompt:
        return {
            "ok": False,
            "answer": None,
            "policy": body.get("policy") or "majority",
            "votes": [],
            "elapsed_ms": 0,
            "error": "prompt required",
        }
    if len(prompt) > MAX_PROMPT_CHARS:
        return {
            "ok": False,
            "answer": None,
            "policy": body.get("policy") or "majority",
            "votes": [],
            "elapsed_ms": 0,
            "error": f"prompt exceeds {MAX_PROMPT_CHARS} chars",
        }

    try:
        n = int(body.get("n") if body.get("n") is not None else 3)
    except (TypeError, ValueError):
        n = 3
    n = max(1, min(MAX_N, n))

    policy = str(body.get("policy") or "majority").strip() or "majority"
    if policy not in ("majority", "love_eq", "unanimous_soft"):
        return {
            "ok": False,
            "answer": None,
            "policy": policy,
            "votes": [],
            "elapsed_ms": 0,
            "error": f"unknown policy: {policy}",
        }

    try:
        timeout_ms = int(body.get("timeout_ms") if body.get("timeout_ms") is not None else 120_000)
    except (TypeError, ValueError):
        timeout_ms = 120_000
    timeout_ms = max(5_000, min(600_000, timeout_ms))

    try:
        temperature = float(body.get("temperature") if body.get("temperature") is not None else 0.6)
    except (TypeError, ValueError):
        temperature = 0.6

    system_prompt = body.get("system_prompt")
    if system_prompt is not None:
        system_prompt = str(system_prompt)

    resolved = _resolve_endpoints(body)
    if isinstance(resolved, str):
        return {
            "ok": False,
            "answer": None,
            "policy": policy,
            "votes": [],
            "elapsed_ms": int((time.time() - t0) * 1000),
            "error": resolved,
        }
    endpoints = resolved

    votes = _fanout_votes(
        prompt=prompt,
        n=n,
        endpoints=endpoints,
        system_prompt=system_prompt,
        temperature=temperature,
        timeout_ms=timeout_ms,
    )

    if not reduce:
        elapsed = int((time.time() - t0) * 1000)
        ok = any(v.get("text") and not v.get("error") for v in votes)
        with _stats_lock:
            _stats["jobs_total"] += 1
            _stats["jobs_ok" if ok else "jobs_err"] += 1
            _stats["elapsed_sum_ms"] += elapsed
        return {
            "ok": ok,
            "votes": votes,
            "elapsed_ms": elapsed,
            "error": None if ok else "all endpoints failed",
        }

    answer: str | None = None
    scores = None
    good = [v for v in votes if v.get("text") and not v.get("error")]

    if not good:
        elapsed = int((time.time() - t0) * 1000)
        with _stats_lock:
            _stats["jobs_total"] += 1
            _stats["jobs_err"] += 1
            _stats["elapsed_sum_ms"] += elapsed
        return {
            "ok": False,
            "answer": None,
            "policy": policy,
            "votes": votes,
            "scores": None,
            "elapsed_ms": elapsed,
            "error": "all endpoints failed: " + "; ".join(
                v.get("error") or "empty" for v in votes
            ),
        }

    remaining_ms = max(5_000, timeout_ms - int((time.time() - t0) * 1000))

    if policy == "love_eq":
        rubric = body.get("rubric")
        rubric = str(rubric).strip() if rubric else (LOVE_EQ_RUBRIC or None)
        scores, why = _love_eq_llm_scores(prompt, good, endpoints, remaining_ms, rubric)
        if scores is None:
            scores = _love_eq_scores(votes, fallback_reason=why)
        by_id = {s["id"]: s for s in scores}
        best = max(good, key=lambda v: by_id.get(v["id"], {}).get("net", 0))
        answer = best["text"]
    elif policy == "unanimous_soft":
        norms = {_normalize(v["text"])[:120] for v in good}
        if len(norms) == 1:
            answer = good[0]["text"]
        else:
            synth = _judge_reduce(prompt, votes, endpoints, remaining_ms)
            answer = synth or _majority_pick(votes)
            if answer and len(norms) > 1:
                answer = (
                    answer.rstrip()
                    + "\n\n[Note: committee was not unanimous; dissent retained in votes.]"
                )
    else:  # majority
        answer = _judge_reduce(prompt, votes, endpoints, remaining_ms) or _majority_pick(
            votes
        )

    elapsed = int((time.time() - t0) * 1000)
    ok = bool(answer)
    with _stats_lock:
        _stats["jobs_total"] += 1
        _stats["jobs_ok" if ok else "jobs_err"] += 1
        _stats["elapsed_sum_ms"] += elapsed

    return {
        "ok": ok,
        "answer": answer,
        "policy": policy,
        "votes": votes,
        "scores": scores,
        "elapsed_ms": elapsed,
        "error": None if ok else "reduce produced empty answer",
    }


class Handler(BaseHTTPRequestHandler):
    server_version = f"zhc-fabric-stub/{VERSION}"

    def log_message(self, fmt: str, *args: Any) -> None:
        # quieter default
        sys_stderr = __import__("sys").stderr
        print(f"[zhc-fabric] {self.address_string()} {fmt % args}", file=sys_stderr)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            _json_response(self, 200, _health())
            return
        if path == "/v1/metrics":
            _json_response(self, 200, _metrics())
            return
        _json_response(self, 404, {"ok": False, "error": f"not found: {path}"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        body = _read_json(self)
        if body is None:
            _json_response(self, 400, {"ok": False, "error": "invalid JSON body"})
            return
        try:
            if path == "/v1/consensus":
                _json_response(self, 200, _run_job(body, reduce=True))
                return
            if path == "/v1/fanout":
                _json_response(self, 200, _run_job(body, reduce=False))
                return
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            _json_response(
                self,
                200,
                {
                    "ok": False,
                    "answer": None,
                    "votes": [],
                    "elapsed_ms": 0,
                    "error": f"internal error: {e}",
                },
            )
            return
        _json_response(self, 404, {"ok": False, "error": f"not found: {path}"})


def main() -> None:
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(
        f"zhc-fabric stub listening on http://{HOST}:{PORT} "
        f"(max_inflight={MAX_INFLIGHT}, default_model={DEFAULT_MODEL or 'unset'})",
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down", flush=True)
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
