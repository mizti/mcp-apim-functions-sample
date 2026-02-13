from __future__ import annotations

import json
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


_MENU_PATH = Path(__file__).with_name("menu.json")


def load_menu() -> dict[str, Any]:
    return json.loads(_MENU_PATH.read_text(encoding="utf-8"))


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class OrderLine:
    menu_item_id: str
    quantity: int
    line_total: int


@dataclass
class Order:
    order_id: str
    status: str
    items: list[OrderLine]
    total: int
    currency: str
    created_at: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "orderId": self.order_id,
            "status": self.status,
            "items": [
                {
                    "menuItemId": line.menu_item_id,
                    "quantity": line.quantity,
                    "lineTotal": line.line_total,
                }
                for line in self.items
            ],
            "total": self.total,
            "currency": self.currency,
            "createdAt": self.created_at,
        }


class InMemoryOrderStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._orders: dict[str, Order] = {}
        self._idempotency: dict[str, str] = {}

    def get_by_id(self, order_id: str) -> Order | None:
        with self._lock:
            return self._orders.get(order_id)

    def get_by_idempotency_key(self, key: str) -> Order | None:
        with self._lock:
            order_id = self._idempotency.get(key)
            return self._orders.get(order_id) if order_id else None

    def save(self, order: Order, idempotency_key: str | None) -> None:
        with self._lock:
            self._orders[order.order_id] = order
            if idempotency_key:
                self._idempotency[idempotency_key] = order.order_id


STORE = InMemoryOrderStore()


class ValidationError(Exception):
    def __init__(self, message: str, status_code: int) -> None:
        super().__init__(message)
        self.status_code = status_code


def create_order(payload: dict[str, Any], idempotency_key: str | None) -> tuple[Order, list[str]]:
    existing = STORE.get_by_idempotency_key(idempotency_key) if idempotency_key else None
    if existing:
        return existing, []

    menu = load_menu()
    expected_version = menu.get("menuVersion", "v1")
    if payload.get("menuVersion") != expected_version:
        raise ValidationError("menuVersion mismatch", 409)

    raw_items = payload.get("items")
    if not isinstance(raw_items, list) or not raw_items:
        raise ValidationError("items must be a non-empty array", 400)

    price_map = {item["id"]: int(item["basePrice"]) for item in menu.get("items", []) if "id" in item}

    lines: list[OrderLine] = []
    total = 0
    for raw in raw_items:
        if not isinstance(raw, dict):
            raise ValidationError("each item must be an object", 400)

        menu_item_id = str(raw.get("menuItemId", ""))
        quantity = raw.get("quantity")

        if not menu_item_id or menu_item_id not in price_map:
            raise ValidationError(f"invalid menuItemId: {menu_item_id}", 400)

        if not isinstance(quantity, int) or quantity <= 0:
            raise ValidationError("quantity must be a positive integer", 400)

        line_total = price_map[menu_item_id] * quantity
        total += line_total
        lines.append(OrderLine(menu_item_id=menu_item_id, quantity=quantity, line_total=line_total))

    order = Order(
        order_id=f"ord_{uuid.uuid4().hex[:8]}",
        status="confirmed",
        items=lines,
        total=total,
        currency="JPY",
        created_at=utc_now_iso(),
    )

    STORE.save(order, idempotency_key=idempotency_key)
    return order, []
