"""zhc-fabric — Hermes plugin: thin client for the consensus fabric sidecar."""

from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path
from typing import Any

from .client import FabricClient
from .config import (
    PLUGIN_ROOT,
    auto_start_enabled,
    fabric_timeout_s,
    fabric_url,
    hermes_home,
    state_dir,
)
from . import schemas

logger = logging.getLogger("zhc-fabric")


def _client(timeout: float | None = None) -> FabricClient:
    return FabricClient(fabric_url(), timeout=timeout or fabric_timeout_s())


def _ensure_sidecar() -> None:
    """Best-effort auto-start; never raises."""
    if not auto_start_enabled():
        return
    try:
        h = _client(timeout=2.0).health()
        if h.get("ok"):
            return
    except Exception:  # noqa: BLE001
        pass
    script = PLUGIN_ROOT / "scripts" / "install-sidecar.sh"
    if not script.is_file():
        logger.warning("zhc-fabric: auto-start enabled but install-sidecar.sh missing")
        return
    try:
        subprocess.Popen(
            ["bash", str(script), "start"],
            cwd=str(PLUGIN_ROOT),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env={**os.environ, "ZHC_FABRIC_ROOT": str(PLUGIN_ROOT)},
        )
        logger.info("zhc-fabric: requested sidecar start via install-sidecar.sh")
    except OSError:
        logger.warning("zhc-fabric: could not auto-start sidecar", exc_info=True)


def _clamp_n(raw: Any, default: int = 3) -> int:
    try:
        n = int(raw if raw is not None else default)
    except (TypeError, ValueError):
        n = default
    return max(1, min(8, n))


def _timeout_ms(params: dict) -> int | None:
    if params.get("timeout_s") is None:
        return None
    try:
        return int(float(params["timeout_s"]) * 1000)
    except (TypeError, ValueError):
        return None


def register(ctx: Any) -> None:
    """Hermes plugin entry — must never raise for missing sidecar."""
    try:
        state_dir()
        _ensure_sidecar()
    except Exception:  # noqa: BLE001
        logger.warning("zhc-fabric: init side effects failed", exc_info=True)

    def fabric_status(params: dict | None = None, **kwargs: Any) -> str:
        del params, kwargs
        out = _client(timeout=3.0).health()
        success = bool(out.get("ok"))
        return json.dumps({"success": success, **out})

    def fabric_consensus(params: dict | None = None, **kwargs: Any) -> str:
        del kwargs
        params = params or {}
        prompt = (params.get("prompt") or "").strip()
        if not prompt:
            return json.dumps({"success": False, "error": "prompt required"})
        n = _clamp_n(params.get("n"), 3)
        policy = (params.get("policy") or "majority").strip() or "majority"
        out = _client().consensus(
            prompt=prompt,
            n=n,
            policy=policy,
            timeout_ms=_timeout_ms(params),
            metadata={"source": "hermes", "hermes_home": str(hermes_home())},
        )
        success = bool(out.get("ok", out.get("success")))
        return json.dumps({"success": success, **out})

    def fabric_fanout(params: dict | None = None, **kwargs: Any) -> str:
        del kwargs
        params = params or {}
        prompt = (params.get("prompt") or "").strip()
        if not prompt:
            return json.dumps({"success": False, "error": "prompt required"})
        n = _clamp_n(params.get("n"), 3)
        out = _client().fanout(
            prompt=prompt,
            n=n,
            timeout_ms=_timeout_ms(params),
            metadata={"source": "hermes"},
        )
        success = bool(out.get("ok", out.get("success")))
        return json.dumps({"success": success, **out})

    try:
        ctx.register_tool(
            name="fabric_status",
            toolset="zhc_fabric",
            schema=schemas.FABRIC_STATUS,
            handler=fabric_status,
            description="Health-check the consensus fabric sidecar.",
        )
        ctx.register_tool(
            name="fabric_consensus",
            toolset="zhc_fabric",
            schema=schemas.FABRIC_CONSENSUS,
            handler=fabric_consensus,
            description="Parallel multi-model consensus via sidecar fabric.",
        )
        ctx.register_tool(
            name="fabric_fanout",
            toolset="zhc_fabric",
            schema=schemas.FABRIC_FANOUT,
            handler=fabric_fanout,
            description="Parallel multi-view fan-out without reduce.",
        )
    except Exception:  # noqa: BLE001
        logger.exception("zhc-fabric: failed to register tools")

    def handle_command(raw_args: str = "") -> str:
        args = (raw_args or "").strip().split()
        if not args or args[0] in ("status", "health"):
            return json.dumps(_client(timeout=3.0).health(), indent=2)
        if args[0] == "start":
            # Force one start attempt even if auto_start env unset
            script = PLUGIN_ROOT / "scripts" / "install-sidecar.sh"
            if script.is_file():
                try:
                    r = subprocess.run(
                        ["bash", str(script), "start"],
                        cwd=str(PLUGIN_ROOT),
                        capture_output=True,
                        text=True,
                        timeout=60,
                    )
                    body = (r.stdout or "") + (r.stderr or "")
                    return body.strip() or f"exit {r.returncode}"
                except Exception as e:  # noqa: BLE001
                    return f"start failed: {e}"
            return "install-sidecar.sh not found"
        if args[0] == "setup":
            script = PLUGIN_ROOT / "scripts" / "setup.sh"
            if not script.is_file():
                return "setup.sh not found — run scripts/setup.sh from a terminal"
            # Interactive TTY required; from chat we only print the path.
            return (
                "Interactive setup needs a terminal:\n"
                f"  bash {script}\n"
                "It asks for base URL, model id, and optional API key, "
                "then starts the sidecar."
            )
        if args[0] == "url":
            return fabric_url()
        return "usage: /fabric [status|start|setup|url]"

    try:
        ctx.register_command(
            "fabric",
            handle_command,
            description="ZHC fabric status/start/setup",
        )
    except Exception:  # noqa: BLE001
        logger.warning("zhc-fabric: register_command failed", exc_info=True)

    skill = PLUGIN_ROOT / "skill" / "SKILL.md"
    if skill.is_file():
        try:
            ctx.register_skill("zhc-fabric", skill)
        except Exception:  # noqa: BLE001
            logger.debug("zhc-fabric: register_skill not available", exc_info=True)

    def on_session_start(**kwargs: Any) -> None:
        del kwargs
        try:
            h = _client(timeout=2.0).health()
            if not h.get("ok"):
                logger.info(
                    "zhc-fabric sidecar offline at %s: %s",
                    fabric_url(),
                    h.get("error", "unknown"),
                )
        except Exception:  # noqa: BLE001
            pass

    try:
        ctx.register_hook("on_session_start", on_session_start)
    except Exception:  # noqa: BLE001
        logger.debug("zhc-fabric: register_hook failed", exc_info=True)
