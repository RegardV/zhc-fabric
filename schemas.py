"""Tool schemas — what the LLM sees."""

FABRIC_STATUS = {
    "name": "fabric_status",
    "description": (
        "Check whether the ZHC consensus fabric sidecar is running and healthy. "
        "Call this before fabric_consensus if unsure the fabric is up."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
        "required": [],
    },
}

FABRIC_CONSENSUS = {
    "name": "fabric_consensus",
    "description": (
        "Run multi-view consensus via the ZHC fabric sidecar: several lightweight "
        "actors propose and critique in parallel, then reduce to one answer. "
        "Use for high-stakes decisions, architecture tradeoffs, risk review, or "
        "when the user asks for a committee/consensus answer. "
        "Do NOT use for trivial facts, single lookups, or latency-sensitive chitchat."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "prompt": {
                "type": "string",
                "description": "Question or decision for the committee to resolve",
            },
            "n": {
                "type": "integer",
                "description": "Number of parallel views (default 3, max 8)",
            },
            "policy": {
                "type": "string",
                "description": "Reduce policy: majority | love_eq | unanimous_soft",
            },
            "timeout_s": {
                "type": "integer",
                "description": "Wall-clock timeout in seconds (optional)",
            },
        },
        "required": ["prompt"],
    },
}

FABRIC_FANOUT = {
    "name": "fabric_fanout",
    "description": (
        "Fan-out only: get N parallel model views from the fabric without reducing "
        "to a single answer. Useful for debugging or presenting raw dissent."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "prompt": {
                "type": "string",
                "description": "Prompt to send to all parallel actors",
            },
            "n": {
                "type": "integer",
                "description": "Number of parallel views (default 3, max 8)",
            },
            "timeout_s": {
                "type": "integer",
                "description": "Wall-clock timeout in seconds (optional)",
            },
        },
        "required": ["prompt"],
    },
}
