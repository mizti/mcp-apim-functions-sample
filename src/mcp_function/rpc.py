from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class ToolCall:
    tool_name: str
    arguments: dict[str, Any]


def parse_tool_context(context: str) -> ToolCall:
    """Parse MCP tool trigger context JSON.

    In the Python v2 MCP tool trigger, the context parameter arrives as a JSON string.
    We keep parsing logic in one place to keep tool handlers small.
    """

    payload = json.loads(context) if context else {}
    return ToolCall(
        tool_name=str(payload.get("toolName", "")),
        arguments=dict(payload.get("arguments", {}) or {}),
    )
