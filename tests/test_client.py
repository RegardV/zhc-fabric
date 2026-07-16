"""Unit tests for FabricClient (no sidecar required for offline cases)."""

from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from client import FabricClient  # noqa: E402


def test_unreachable():
    c = FabricClient("http://127.0.0.1:1", timeout=1)
    h = c.health()
    assert h.get("ok") is False
    assert "error" in h


def test_health_and_consensus_mock():
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):  # noqa: ANN001
            return

        def do_GET(self):  # noqa: N802
            body = json.dumps({"ok": True, "api": "v1", "version": "0.1.0"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):  # noqa: N802
            body = json.dumps(
                {
                    "ok": True,
                    "answer": "4",
                    "policy": "majority",
                    "votes": [],
                    "elapsed_ms": 1,
                    "error": None,
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    httpd = HTTPServer(("127.0.0.1", 0), H)
    port = httpd.server_address[1]
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    try:
        c = FabricClient(f"http://127.0.0.1:{port}", timeout=5)
        assert c.health()["ok"] is True
        r = c.consensus("2+2?", n=2)
        assert r["ok"] is True
        assert r["answer"] == "4"
    finally:
        httpd.shutdown()


if __name__ == "__main__":
    test_unreachable()
    test_health_and_consensus_mock()
    print("test_client OK")
