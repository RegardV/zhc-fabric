"""Contract tests for the sidecar HTTP API (spec: docs/SIDECAR-API.md).

Runs fully offline: an in-process mock OpenAI server plays the inference
backend. By default a stub sidecar subprocess is started on an ephemeral port.
Set FABRIC_TEST_URL to point at an already-running sidecar (e.g. the OTP
implementation in docker --network=host) to verify it against the same
contract; the mock OpenAI endpoint is passed explicitly in request bodies so
both modes work unchanged.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STUB = ROOT / "sidecar" / "stub" / "server.py"

MOCK_ANSWER = "The answer is 4."


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _MockOpenAI(BaseHTTPRequestHandler):
    def log_message(self, *a):  # noqa: ANN002
        return

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        body = json.dumps(
            {"choices": [{"message": {"role": "assistant", "content": MOCK_ANSWER}}]}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _post(base: str, path: str, body: dict) -> dict:
    req = urllib.request.Request(
        f"{base}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def _get(base: str, path: str) -> dict:
    with urllib.request.urlopen(f"{base}{path}", timeout=5) as resp:
        return json.loads(resp.read().decode())


class Fixture:
    """Mock OpenAI server + sidecar (subprocess unless FABRIC_TEST_URL set)."""

    def __enter__(self) -> "Fixture":
        self.mock_port = _free_port()
        self.mock = ThreadingHTTPServer(("127.0.0.1", self.mock_port), _MockOpenAI)
        threading.Thread(target=self.mock.serve_forever, daemon=True).start()
        self.endpoints = [
            {
                "name": "mock",
                "base_url": f"http://127.0.0.1:{self.mock_port}/v1",
                "model": "mock-1",
            }
        ]
        self.proc = None
        ext = os.environ.get("FABRIC_TEST_URL", "").strip()
        if ext:
            self.base = ext.rstrip("/")
            return self
        port = _free_port()
        self.base = f"http://127.0.0.1:{port}"
        env = {**os.environ, "FABRIC_PORT": str(port), "DEFAULT_BASE_URL": "", "DEFAULT_MODEL": ""}
        self.proc = subprocess.Popen(
            [sys.executable, str(STUB)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                if _get(self.base, "/health").get("ok"):
                    return self
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("sidecar did not become healthy")

    def __exit__(self, *a) -> None:  # noqa: ANN002
        self.mock.shutdown()
        if self.proc:
            self.proc.terminate()
            self.proc.wait(timeout=5)


def check_health(f: Fixture) -> None:
    h = _get(f.base, "/health")
    assert h["ok"] is True
    assert h["api"] == "v1"
    assert isinstance(h["version"], str)
    assert isinstance(h["max_inflight"], int)


def check_consensus_majority(f: Fixture) -> None:
    r = _post(f.base, "/v1/consensus", {"prompt": "2+2?", "n": 3, "policy": "majority", "endpoints": f.endpoints})
    assert r["ok"] is True, r
    assert r["answer"] == MOCK_ANSWER
    assert r["policy"] == "majority"
    assert len(r["votes"]) == 3
    for v in r["votes"]:
        assert v["role"] in ("proposer", "critic")
        assert v["model"] == "mock-1"
        assert v["text"] == MOCK_ANSWER
        assert isinstance(v["latency_ms"], int)
        assert v["error"] is None
    assert isinstance(r["elapsed_ms"], int)
    assert r["error"] is None


def check_fanout(f: Fixture) -> None:
    r = _post(f.base, "/v1/fanout", {"prompt": "2+2?", "n": 2, "endpoints": f.endpoints})
    assert r["ok"] is True, r
    assert len(r["votes"]) == 2
    assert all(v["text"] == MOCK_ANSWER for v in r["votes"])


def check_error_paths(f: Fixture) -> None:
    r = _post(f.base, "/v1/consensus", {"prompt": "", "endpoints": f.endpoints})
    assert r["ok"] is False and r["error"]
    r = _post(f.base, "/v1/consensus", {"prompt": "x", "policy": "nope", "endpoints": f.endpoints})
    assert r["ok"] is False and "policy" in r["error"]
    r = _post(f.base, "/v1/consensus", {"prompt": "x", "endpoints": [{"name": "bad"}]})
    assert r["ok"] is False and r["error"]


def check_n_clamped(f: Fixture) -> None:
    r = _post(f.base, "/v1/consensus", {"prompt": "2+2?", "n": 999, "endpoints": f.endpoints})
    assert r["ok"] is True, r
    assert len(r["votes"]) <= 16


CHECKS = [check_health, check_consensus_majority, check_fanout, check_error_paths, check_n_clamped]


def test_api_contract():
    with Fixture() as f:
        for check in CHECKS:
            check(f)


if __name__ == "__main__":
    test_api_contract()
    print("test_api_contract OK")
