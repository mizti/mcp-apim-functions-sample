from __future__ import annotations

import json
import logging
from typing import Any

import azure.functions as func

from shipments import STORE, ValidationError, create_shipment

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


def _json_response(payload: Any, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        body=json.dumps(payload, ensure_ascii=False),
        status_code=status_code,
        mimetype="application/json",
    )


@app.route(route="shipments", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def post_shipments(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("POST /api/shipments")

    try:
        payload = req.get_json()
    except ValueError:
        return _json_response({"error": "invalid json"}, status_code=400)

    if not isinstance(payload, dict):
        return _json_response({"error": "body must be a json object"}, status_code=400)

    idempotency_key = req.headers.get("Idempotency-Key")

    try:
        shipment, warnings = create_shipment(payload, idempotency_key=idempotency_key)
    except ValidationError as ex:
        return _json_response({"error": str(ex)}, status_code=ex.status_code)

    response = {
        "trackingId": shipment.tracking_id,
        "status": shipment.status,
        "createdAt": shipment.created_at,
        "validationWarnings": warnings,
    }

    return _json_response(response, status_code=200)


@app.route(route="shipments/{trackingId}", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def get_shipment(req: func.HttpRequest) -> func.HttpResponse:
    tracking_id = req.route_params.get("trackingId", "")
    logging.info("GET /api/shipments/%s", tracking_id)

    if not tracking_id:
        return _json_response({"error": "missing trackingId"}, status_code=400)

    shipment = STORE.get_by_id(tracking_id)
    if not shipment:
        return _json_response({"error": "shipment not found"}, status_code=404)

    return _json_response(shipment.to_dict(), status_code=200)
