from __future__ import annotations

import json
import os
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from azure.storage.blob import BlobServiceClient  # type: ignore
except Exception:  # pragma: no cover
    BlobServiceClient = None  # type: ignore

try:
    from azure.identity import DefaultAzureCredential  # type: ignore
except Exception:  # pragma: no cover
    DefaultAzureCredential = None  # type: ignore


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


def _order_from_dict(data: dict[str, Any]) -> Order:
    items: list[OrderLine] = []
    for raw in data.get("items", []) or []:
        if not isinstance(raw, dict):
            continue
        items.append(
            OrderLine(
                menu_item_id=str(raw.get("menuItemId", "")),
                quantity=int(raw.get("quantity", 0) or 0),
                line_total=int(raw.get("lineTotal", 0) or 0),
            )
        )

    return Order(
        order_id=str(data.get("orderId", "")),
        status=str(data.get("status", "")),
        items=items,
        total=int(data.get("total", 0) or 0),
        currency=str(data.get("currency", "")),
        created_at=str(data.get("createdAt", "")),
    )


class BlobOrderStore:
    def __init__(
        self,
        *,
        connection_string: str | None = None,
        account_url: str | None = None,
        container_name: str = "orders",
    ) -> None:
        if BlobServiceClient is None:
            raise RuntimeError("azure-storage-blob is not available")

        if connection_string:
            self._service = BlobServiceClient.from_connection_string(connection_string)
        else:
            if not account_url:
                raise RuntimeError("account_url is required when connection_string is not provided")
            if DefaultAzureCredential is None:
                raise RuntimeError("azure-identity is not available")

            credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
            self._service = BlobServiceClient(account_url=account_url, credential=credential)
        self._container = self._service.get_container_client(container_name)
        try:
            self._container.create_container()
        except Exception:
            # Container likely already exists.
            pass

    def _order_blob_name(self, order_id: str) -> str:
        return f"orders/{order_id}.json"

    def _idem_blob_name(self, key: str) -> str:
        return f"idempotency/{key}.txt"

    def get_by_id(self, order_id: str) -> Order | None:
        try:
            blob = self._container.get_blob_client(self._order_blob_name(order_id))
            data = blob.download_blob().readall()
        except Exception:
            return None

        try:
            obj = json.loads((data or b"{}").decode("utf-8"))
            return _order_from_dict(obj) if isinstance(obj, dict) else None
        except Exception:
            return None

    def get_by_idempotency_key(self, key: str) -> Order | None:
        try:
            blob = self._container.get_blob_client(self._idem_blob_name(key))
            data = blob.download_blob().readall()
            order_id = (data or b"").decode("utf-8").strip()
        except Exception:
            return None

        return self.get_by_id(order_id) if order_id else None

    def save(self, order: Order, idempotency_key: str | None) -> None:
        payload = json.dumps(order.to_dict(), ensure_ascii=False).encode("utf-8")
        self._container.upload_blob(self._order_blob_name(order.order_id), payload, overwrite=True)
        if idempotency_key:
            self._container.upload_blob(self._idem_blob_name(idempotency_key), order.order_id.encode("utf-8"), overwrite=True)


def _get_store() -> InMemoryOrderStore | BlobOrderStore:
    # Option A: classic connection-string based setting
    connection_string = os.environ.get("AzureWebJobsStorage")
    if connection_string and BlobServiceClient is not None:
        try:
            return BlobOrderStore(connection_string=connection_string)
        except Exception:
            return InMemoryOrderStore()

    # Option B: Flex Consumption / identity-based storage (accountName only)
    account_name = os.environ.get("AzureWebJobsStorage__accountName")
    if account_name and BlobServiceClient is not None and DefaultAzureCredential is not None:
        account_url = f"https://{account_name}.blob.core.windows.net"
        try:
            return BlobOrderStore(account_url=account_url)
        except Exception:
            return InMemoryOrderStore()
    return InMemoryOrderStore()


# Use a stable store per worker process.
STORE = _get_store()


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
