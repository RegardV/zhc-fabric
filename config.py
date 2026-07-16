"""Portable config resolution for zhc-fabric plugin + scripts."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

DEFAULT_FABRIC_URL = "http://127.0.0.1:7733"
DEFAULT_TIMEOUT_S = 120.0
PLUGIN_ROOT = Path(__file__).resolve().parent


def hermes_home() -> Path:
    raw = os.environ.get("HERMES_HOME") or str(Path.home() / ".hermes")
    return Path(raw).expanduser().resolve()


def state_dir() -> Path:
    d = hermes_home() / "zhc-fabric"
    d.mkdir(parents=True, exist_ok=True)
    return d


def fabric_url() -> str:
    if u := os.environ.get("ZHC_FABRIC_URL", "").strip():
        return u.rstrip("/")
    cfg_path = state_dir() / "config.json"
    if cfg_path.is_file():
        try:
            data = json.loads(cfg_path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and data.get("url"):
                return str(data["url"]).rstrip("/")
        except (OSError, json.JSONDecodeError, TypeError):
            pass
    return DEFAULT_FABRIC_URL


def fabric_timeout_s() -> float:
    raw = os.environ.get("ZHC_FABRIC_TIMEOUT_S", "").strip()
    if not raw:
        return DEFAULT_TIMEOUT_S
    try:
        return max(1.0, float(raw))
    except ValueError:
        return DEFAULT_TIMEOUT_S


def auto_start_enabled() -> bool:
    return os.environ.get("ZHC_FABRIC_AUTO_START", "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )


def load_state_config() -> dict[str, Any]:
    cfg_path = state_dir() / "config.json"
    if not cfg_path.is_file():
        return {}
    try:
        data = json.loads(cfg_path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}
