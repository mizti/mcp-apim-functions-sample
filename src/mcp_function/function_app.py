from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

import azure.functions as func

from rpc import parse_tool_context

app = func.FunctionApp()


_TOOL_PROPERTIES_MENU_DETAILS = json.dumps(
    [
        {
            "name": "itemId",
            "propertyType": "string",
            "description": "Menu item id (example: ramen-shoyu)",
            "required": True,
        }
    ],
    ensure_ascii=False,
)


def _load_menu() -> dict[str, Any]:
    menu_path = Path(__file__).with_name("menu.json")
    return json.loads(menu_path.read_text(encoding="utf-8"))


@app.mcp_tool_trigger(
    arg_name="context",
    tool_name="get_list_menus",
    description="Get the restaurant menu list.",
    tool_properties=json.dumps([], ensure_ascii=False),
)
def get_list_menus(context: str) -> str:
    _ = parse_tool_context(context)

    menu = _load_menu()
    items = menu.get("items", [])

    response = {
        "menuVersion": menu.get("menuVersion", "v1"),
        "categories": menu.get("categories", []),
        "items": [
            {
                "id": item.get("id"),
                "name": item.get("name"),
                "category": item.get("category"),
                "basePrice": item.get("basePrice"),
                "available": item.get("available", True),
            }
            for item in items
        ],
    }

    logging.info("MCP tool get_list_menus called")
    return json.dumps(response, ensure_ascii=False)


@app.mcp_tool_trigger(
    arg_name="context",
    tool_name="get_menu_details",
    description="Get details for a specific menu item.",
    tool_properties=_TOOL_PROPERTIES_MENU_DETAILS,
)
def get_menu_details(context: str) -> str:
    call = parse_tool_context(context)
    item_id = str(call.arguments.get("itemId", ""))

    if not item_id:
        return "Missing required argument: itemId"

    menu = _load_menu()
    items = menu.get("items", [])

    item = next((x for x in items if x.get("id") == item_id), None)
    if not item:
        return f"Menu item not found: {item_id}"

    response = {
        "id": item.get("id"),
        "name": item.get("name"),
        "description": item.get("description", ""),
        "basePrice": item.get("basePrice"),
        "allergens": item.get("allergens", []),
        "options": item.get("options", []),
    }

    logging.info("MCP tool get_menu_details called: %s", item_id)
    return json.dumps(response, ensure_ascii=False)


@app.mcp_tool_trigger(
    arg_name="context",
    tool_name="get_constraints",
    description="Get ordering constraints (hours, limits, notes).",
    tool_properties=json.dumps([], ensure_ascii=False),
)
def get_constraints(context: str) -> str:
    _ = parse_tool_context(context)

    menu = _load_menu()
    constraints = menu.get("constraints", {})

    response = {
        "openHours": constraints.get("openHours", "11:00-21:00"),
        "maxItemsPerOrder": constraints.get("maxItemsPerOrder", 10),
        "notes": constraints.get("notes", []),
    }

    logging.info("MCP tool get_constraints called")
    return json.dumps(response, ensure_ascii=False)
