"""Source adapter registry.

Adding a source is: write one module under app/sources/ that defines a payload
model and a handler, then register it. Nothing else in the service changes -
routes, auth, and batch auditing are generated from what is registered here.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

from psycopg import Connection
from pydantic import BaseModel


@dataclass
class IngestResult:
    rows_written: int = 0
    detail: dict[str, Any] = field(default_factory=dict)
    window: tuple[Any, Any] | None = None


@dataclass(frozen=True)
class Adapter:
    key: str                                   # matches health.sources.key
    summary: str
    model: type[BaseModel]
    handler: Callable[[Any, Connection], IngestResult]


REGISTRY: dict[str, Adapter] = {}


def register(adapter: Adapter) -> Adapter:
    if adapter.key in REGISTRY:
        raise RuntimeError(f"Duplicate source adapter: {adapter.key}")
    REGISTRY[adapter.key] = adapter
    return adapter


def source_id(conn: Connection, key: str) -> int:
    row = conn.execute("SELECT id FROM health.sources WHERE key = %s", (key,)).fetchone()
    if row is None:
        raise RuntimeError(f"Source {key!r} is not registered in health.sources")
    return row[0]
