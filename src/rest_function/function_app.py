from __future__ import annotations

import json
import logging
from typing import Any

import azure.functions as func

from orders import STORE, ValidationError, create_order

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


def _json_response(payload: Any, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        body=json.dumps(payload, ensure_ascii=False),
        status_code=status_code,
        mimetype="application/json",
    )


@app.route(route="api/orders", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def post_orders(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("POST /api/orders")

    try:
        payload = req.get_json()
    except ValueError:
        return _json_response({"error": "invalid json"}, status_code=400)

    if not isinstance(payload, dict):
        return _json_response({"error": "body must be a json object"}, status_code=400)

    idempotency_key = req.headers.get("Idempotency-Key")

    try:
        order, warnings = create_order(payload, idempotency_key=idempotency_key)
    except ValidationError as ex:
        return _json_response({"error": str(ex)}, status_code=ex.status_code)

    response = {
        "orderId": order.order_id,
        "status": order.status,
        "total": order.total,
        "currency": order.currency,
        "createdAt": order.created_at,
        "validationWarnings": warnings,
    }

    return _json_response(response, status_code=200)


@app.route(route="api/orders/{orderId}", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def get_order(req: func.HttpRequest) -> func.HttpResponse:
    order_id = req.route_params.get("orderId", "")
    logging.info("GET /api/orders/%s", order_id)

    if not order_id:
        return _json_response({"error": "missing orderId"}, status_code=400)

    order = STORE.get_by_id(order_id)
    if not order:
        return _json_response({"error": "order not found"}, status_code=404)

    return _json_response(order.to_dict(), status_code=200)
