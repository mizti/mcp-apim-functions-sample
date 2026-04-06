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


_DATA_PATH = Path(__file__).with_name("shipments.json")


def load_rules() -> dict[str, Any]:
    data = json.loads(_DATA_PATH.read_text(encoding="utf-8"))
    return data.get("rules", {})


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class Shipment:
    tracking_id: str
    status: str
    sender_name: str
    recipient_name: str
    from_address: str
    to_address: str
    weight_kg: float
    size_cm: str
    note: str
    created_at: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "trackingId": self.tracking_id,
            "status": self.status,
            "senderName": self.sender_name,
            "recipientName": self.recipient_name,
            "from": self.from_address,
            "to": self.to_address,
            "weightKg": self.weight_kg,
            "sizeCm": self.size_cm,
            "note": self.note,
            "createdAt": self.created_at,
        }


class InMemoryShipmentStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._shipments: dict[str, Shipment] = {}
        self._idempotency: dict[str, str] = {}

    def get_by_id(self, tracking_id: str) -> Shipment | None:
        with self._lock:
            return self._shipments.get(tracking_id)

    def get_by_idempotency_key(self, key: str) -> Shipment | None:
        with self._lock:
            tracking_id = self._idempotency.get(key)
            return self._shipments.get(tracking_id) if tracking_id else None

    def save(self, shipment: Shipment, idempotency_key: str | None) -> None:
        with self._lock:
            self._shipments[shipment.tracking_id] = shipment
            if idempotency_key:
                self._idempotency[idempotency_key] = shipment.tracking_id


def _shipment_from_dict(data: dict[str, Any]) -> Shipment:
    return Shipment(
        tracking_id=str(data.get("trackingId", "")),
        status=str(data.get("status", "")),
        sender_name=str(data.get("senderName", "")),
        recipient_name=str(data.get("recipientName", "")),
        from_address=str(data.get("from", "")),
        to_address=str(data.get("to", "")),
        weight_kg=float(data.get("weightKg", 0) or 0),
        size_cm=str(data.get("sizeCm", "")),
        note=str(data.get("note", "")),
        created_at=str(data.get("createdAt", "")),
    )


class BlobShipmentStore:
    def __init__(
        self,
        *,
        connection_string: str | None = None,
        account_url: str | None = None,
        container_name: str = "shipments",
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
            pass

    def _shipment_blob_name(self, tracking_id: str) -> str:
        return f"shipments/{tracking_id}.json"

    def _idem_blob_name(self, key: str) -> str:
        return f"idempotency/{key}.txt"

    def get_by_id(self, tracking_id: str) -> Shipment | None:
        try:
            blob = self._container.get_blob_client(self._shipment_blob_name(tracking_id))
            data = blob.download_blob().readall()
        except Exception:
            return None

        try:
            obj = json.loads((data or b"{}").decode("utf-8"))
            return _shipment_from_dict(obj) if isinstance(obj, dict) else None
        except Exception:
            return None

    def get_by_idempotency_key(self, key: str) -> Shipment | None:
        try:
            blob = self._container.get_blob_client(self._idem_blob_name(key))
            data = blob.download_blob().readall()
            tracking_id = (data or b"").decode("utf-8").strip()
        except Exception:
            return None

        return self.get_by_id(tracking_id) if tracking_id else None

    def save(self, shipment: Shipment, idempotency_key: str | None) -> None:
        payload = json.dumps(shipment.to_dict(), ensure_ascii=False).encode("utf-8")
        self._container.upload_blob(self._shipment_blob_name(shipment.tracking_id), payload, overwrite=True)
        if idempotency_key:
            self._container.upload_blob(self._idem_blob_name(idempotency_key), shipment.tracking_id.encode("utf-8"), overwrite=True)


def _get_store() -> InMemoryShipmentStore | BlobShipmentStore:
    connection_string = os.environ.get("AzureWebJobsStorage")
    if connection_string and BlobServiceClient is not None:
        try:
            return BlobShipmentStore(connection_string=connection_string)
        except Exception:
            return InMemoryShipmentStore()

    account_name = os.environ.get("AzureWebJobsStorage__accountName")
    if account_name and BlobServiceClient is not None and DefaultAzureCredential is not None:
        account_url = f"https://{account_name}.blob.core.windows.net"
        try:
            return BlobShipmentStore(account_url=account_url)
        except Exception:
            return InMemoryShipmentStore()
    return InMemoryShipmentStore()


STORE = _get_store()


class ValidationError(Exception):
    def __init__(self, message: str, status_code: int) -> None:
        super().__init__(message)
        self.status_code = status_code


def create_shipment(payload: dict[str, Any], idempotency_key: str | None) -> tuple[Shipment, list[str]]:
    existing = STORE.get_by_idempotency_key(idempotency_key) if idempotency_key else None
    if existing:
        return existing, []

    rules = load_rules()

    recipient_name = str(payload.get("recipientName", "")).strip()
    if not recipient_name:
        raise ValidationError("recipientName is required", 400)

    from_address = str(payload.get("from", "")).strip()
    if not from_address:
        raise ValidationError("from is required", 400)

    to_address = str(payload.get("to", "")).strip()
    if not to_address:
        raise ValidationError("to is required", 400)

    weight_kg = payload.get("weightKg")
    if weight_kg is not None:
        try:
            weight_kg = float(weight_kg)
        except (TypeError, ValueError):
            raise ValidationError("weightKg must be a number", 400)
        max_weight = rules.get("maxWeightKg", 30)
        if weight_kg > max_weight:
            raise ValidationError(f"weightKg exceeds limit ({max_weight}kg)", 400)
    else:
        weight_kg = 0

    shipment = Shipment(
        tracking_id=f"QS-{uuid.uuid4().hex[:8]}",
        status="pending",
        sender_name=str(payload.get("senderName", "")).strip(),
        recipient_name=recipient_name,
        from_address=from_address,
        to_address=to_address,
        weight_kg=weight_kg,
        size_cm=str(payload.get("sizeCm", "")).strip(),
        note=str(payload.get("note", "")).strip(),
        created_at=utc_now_iso(),
    )

    STORE.save(shipment, idempotency_key=idempotency_key)
    return shipment, []
