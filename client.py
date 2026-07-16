"""Stdlib HTTP client for the zhc-fabric sidecar. Never raises to callers."""

from __future__ import annotations

import json
import socket
import urllib.error
import urllib.request
from typing import Any


class FabricClient:
    def __init__(self, base_url: str, timeout: float = 120.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = float(timeout)

    def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        url = f"{self.base_url}{path}"
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        to = self.timeout if timeout is None else timeout
        try:
            with urllib.request.urlopen(req, timeout=to) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                if not raw.strip():
                    return {"ok": False, "error": "empty response from fabric"}
                try:
                    parsed = json.loads(raw)
                except json.JSONDecodeError:
                    return {
                        "ok": False,
                        "error": f"non-json response from fabric: {raw[:200]}",
                    }
                if not isinstance(parsed, dict):
                    return {"ok": False, "error": "fabric response was not an object"}
                return parsed
        except urllib.error.HTTPError as e:
            try:
                raw = e.read().decode("utf-8", errors="replace")
                parsed = json.loads(raw) if raw.strip() else {}
                if isinstance(parsed, dict) and parsed:
                    parsed.setdefault("ok", False)
                    parsed.setdefault("error", f"HTTP {e.code}")
                    return parsed
            except Exception:
                pass
            return {"ok": False, "error": f"HTTP {e.code}: {e.reason}"}
        except urllib.error.URLError as e:
            reason = getattr(e, "reason", e)
            return {"ok": False, "error": f"fabric unreachable: {reason}"}
        except TimeoutError:
            return {"ok": False, "error": "fabric timeout"}
        except socket.timeout:
            return {"ok": False, "error": "fabric timeout"}
        except Exception as e:  # noqa: BLE001 — boundary
            return {"ok": False, "error": f"fabric client error: {e}"}

    def health(self) -> dict[str, Any]:
        return self._request("GET", "/health", timeout=min(3.0, self.timeout))

    def consensus(
        self,
        prompt: str,
        n: int = 3,
        policy: str = "majority",
        timeout_ms: int | None = None,
        **extra: Any,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "prompt": prompt,
            "n": n,
            "policy": policy,
        }
        if timeout_ms is not None:
            body["timeout_ms"] = timeout_ms
        body.update(extra)
        # Wall timeout slightly above job timeout if provided
        client_to = self.timeout
        if timeout_ms is not None:
            client_to = max(self.timeout, (timeout_ms / 1000.0) + 5.0)
        return self._request("POST", "/v1/consensus", body=body, timeout=client_to)

    def fanout(
        self,
        prompt: str,
        n: int = 3,
        timeout_ms: int | None = None,
        **extra: Any,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"prompt": prompt, "n": n}
        if timeout_ms is not None:
            body["timeout_ms"] = timeout_ms
        body.update(extra)
        client_to = self.timeout
        if timeout_ms is not None:
            client_to = max(self.timeout, (timeout_ms / 1000.0) + 5.0)
        return self._request("POST", "/v1/fanout", body=body, timeout=client_to)
