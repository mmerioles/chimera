"""Health ingest API.

Routes are generated from the adapter registry, so a new source needs no
changes here.
"""
# Note: no `from __future__ import annotations` in this module. FastAPI reads
# the payload type off each generated endpoint's signature, and that needs the
# annotation to be the class object rather than a deferred string.

import hashlib
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import Body, Depends, FastAPI, HTTPException, Request
from psycopg.types.json import Jsonb
from pydantic import BaseModel

from . import db
from .auth import require_token
from .config import settings
from .registry import REGISTRY, Adapter, source_id
from . import sources  # noqa: F401  - importing registers every adapter

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("health.ingest")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.pool.open()
    db.pool.wait(timeout=30)
    if settings.run_migrations:
        applied = db.run_migrations()
        log.info("migrations applied: %s", applied or "none pending")
    db.apply_runtime_config()
    db.ensure_readonly_role()
    log.info("registered sources: %s", ", ".join(sorted(REGISTRY)))
    yield
    db.pool.close()


app = FastAPI(
    title="Chimera Health Ingest",
    version="0.1.0",
    summary="Write path for the health dashboard",
    lifespan=lifespan,
)


@app.get("/healthz", tags=["ops"])
def healthz() -> dict[str, Any]:
    with db.pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok", "sources": sorted(REGISTRY)}


@app.get("/v1/sources", tags=["ops"])
def list_sources() -> list[dict[str, str]]:
    return [
        {"key": a.key, "summary": a.summary, "endpoint": f"/v1/ingest/{a.key}"}
        for a in sorted(REGISTRY.values(), key=lambda a: a.key)
    ]


def _make_endpoint(adapter: Adapter):
    Payload = adapter.model

    def endpoint(request: Request, payload: Payload, _=Depends(require_token)):
        raw = getattr(request.state, "raw_body", b"")
        digest = hashlib.sha256(raw).hexdigest()

        with db.pool.connection() as conn:
            try:
                result = adapter.handler(payload, conn)
                status_text, detail = "ok", result.detail
            except Exception as exc:
                log.exception("ingest failed for %s", adapter.key)
                conn.rollback()
                with db.pool.connection() as audit:
                    audit.execute(
                        """
                        INSERT INTO health.ingest_batches
                          (source_id, payload_sha256, payload_bytes, status, detail)
                        VALUES (%s, %s, %s, 'error', %s)
                        """,
                        (source_id(audit, adapter.key), digest, len(raw),
                         Jsonb({"error": str(exc)[:2000]})),
                    )
                    audit.commit()
                raise HTTPException(status_code=500, detail=f"ingest failed: {exc}")

            window = result.window or (None, None)
            conn.execute(
                """
                INSERT INTO health.ingest_batches
                  (source_id, payload_sha256, payload_bytes, window_start,
                   window_end, rows_written, status, detail)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (source_id(conn, adapter.key), digest, len(raw),
                 window[0], window[1], result.rows_written, status_text, Jsonb(detail)),
            )
            conn.commit()

        return {"status": status_text, "rows_written": result.rows_written, "detail": detail}

    endpoint.__name__ = f"ingest_{adapter.key}"
    return endpoint


@app.middleware("http")
async def capture_raw_body(request: Request, call_next):
    """Stash the raw body so batches can be hashed for audit and dedupe."""
    if request.method == "POST":
        request.state.raw_body = await request.body()
    return await call_next(request)


for _adapter in REGISTRY.values():
    app.add_api_route(
        f"/v1/ingest/{_adapter.key}",
        _make_endpoint(_adapter),
        methods=["POST"],
        tags=["ingest"],
        summary=_adapter.summary,
    )


class RebuildRequest(BaseModel):
    source: str
    start: datetime | None = None
    end: datetime | None = None
    days: int | None = None


@app.post("/v1/admin/rebuild", tags=["ops"], dependencies=[Depends(require_token)])
def rebuild(req: RebuildRequest = Body(...)) -> dict[str, Any]:
    """Re-derive observations from the raw layer.

    This is the escape hatch that makes the raw layer worth keeping: change a
    bucketing rule, then replay it over history.
    """
    fns = {"phone_screentime": "health.rebuild_screentime"}
    if req.source not in fns:
        raise HTTPException(400, f"No rebuild function for source {req.source!r}")

    end = req.end or datetime.now(timezone.utc)
    start = req.start or (end - timedelta(days=req.days or 30))

    with db.pool.connection() as conn:
        written = conn.execute(
            f"SELECT {fns[req.source]}(%s, %s)", (start, end)
        ).fetchone()[0]
        conn.commit()

    return {"source": req.source, "start": start, "end": end, "observations_written": written}
