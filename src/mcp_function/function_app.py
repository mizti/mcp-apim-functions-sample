from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

import azure.functions as func

from rpc import parse_tool_context

app = func.FunctionApp()


_TOOL_PROPERTIES_TRACKING_ID = json.dumps(
    [
        {
            "name": "trackingId",
            "propertyType": "string",
            "description": "Tracking ID (example: QS-001)",
            "required": True,
        }
    ],
    ensure_ascii=False,
)


def _load_data() -> dict[str, Any]:
    data_path = Path(__file__).with_name("shipments.json")
    return json.loads(data_path.read_text(encoding="utf-8"))


@app.mcp_tool_trigger(
    arg_name="context",
    tool_name="track_shipment",
    description="Track a shipment status by tracking ID.",
    tool_properties=_TOOL_PROPERTIES_TRACKING_ID,
)
def track_shipment(context: str) -> str:
    call = parse_tool_context(context)
    tracking_id = str(call.arguments.get("trackingId", ""))

    if not tracking_id:
        return "Missing required argument: trackingId"

    data = _load_data()
    shipments = data.get("shipments", [])

    shipment = next((s for s in shipments if s.get("trackingId") == tracking_id), None)
    if not shipment:
        return f"Shipment not found: {tracking_id}"

    response = {
        "trackingId": shipment.get("trackingId"),
        "status": shipment.get("status"),
        "lastUpdated": shipment.get("lastUpdated", ""),
    }

    logging.info("MCP tool track_shipment called: %s", tracking_id)
    return json.dumps(response, ensure_ascii=False)


@app.mcp_tool_trigger(
    arg_name="context",
    tool_name="get_shipment_details",
    description="Get full details for a shipment by tracking ID.",
    tool_properties=_TOOL_PROPERTIES_TRACKING_ID,
)
def get_shipment_details(context: str) -> str:
    call = parse_tool_context(context)
    tracking_id = str(call.arguments.get("trackingId", ""))

    if not tracking_id:
        return "Missing required argument: trackingId"

    data = _load_data()
    shipments = data.get("shipments", [])

    shipment = next((s for s in shipments if s.get("trackingId") == tracking_id), None)
    if not shipment:
        return f"Shipment not found: {tracking_id}"

    response = {
        "trackingId": shipment.get("trackingId"),
        "status": shipment.get("status"),
        "senderName": shipment.get("senderName", ""),
        "recipientName": shipment.get("recipientName", ""),
        "from": shipment.get("from", ""),
        "to": shipment.get("to", ""),
        "weightKg": shipment.get("weightKg"),
        "sizeCm": shipment.get("sizeCm", ""),
        "createdAt": shipment.get("createdAt", ""),
        "lastUpdated": shipment.get("lastUpdated", ""),
    }

    logging.info("MCP tool get_shipment_details called: %s", tracking_id)
    return json.dumps(response, ensure_ascii=False)


@app.mcp_tool_trigger(
    arg_name="context",
    tool_name="get_shipping_rules",
    description="Get shipping rules and constraints (hours, weight limits, prohibited items, service area).",
    tool_properties=json.dumps([], ensure_ascii=False),
)
def get_shipping_rules(context: str) -> str:
    _ = parse_tool_context(context)

    data = _load_data()
    rules = data.get("rules", {})

    response = {
        "acceptanceHours": rules.get("acceptanceHours", "08:00-20:00"),
        "maxWeightKg": rules.get("maxWeightKg", 30),
        "maxSizeCm": rules.get("maxSizeCm", "3辺合計160cm以内"),
        "maxPackagesPerRequest": rules.get("maxPackagesPerRequest", 5),
        "prohibitedItems": rules.get("prohibitedItems", []),
        "serviceArea": rules.get("serviceArea", "全国（離島除く）"),
    }

    logging.info("MCP tool get_shipping_rules called")
    return json.dumps(response, ensure_ascii=False)
