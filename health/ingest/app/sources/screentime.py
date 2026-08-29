"""Phone screen time.

The phone uploads raw intervals and events, not rollups. Everything the
dashboard shows is derived server-side by health.rebuild_screentime(), so
changing how usage is bucketed later is a backfill over existing raw data
rather than a permanent gap.
"""
from __future__ import annotations

from datetime import datetime

from psycopg import Connection
from psycopg.types.json import Jsonb
from pydantic import AwareDatetime, BaseModel, Field, model_validator

from ..registry import Adapter, IngestResult, register, source_id

SOURCE_KEY = "phone_screentime"


def _ms(ts: datetime) -> int:
    return int(ts.timestamp() * 1000)


class AppInfo(BaseModel):
    package: str = Field(min_length=1, max_length=255)
    label: str | None = Field(default=None, max_length=255)


class Interval(BaseModel):
    start: AwareDatetime
    end: AwareDatetime

    @model_validator(mode="after")
    def _ordered(self):
        if self.end < self.start:
            raise ValueError("end must not precede start")
        return self


class AppSession(Interval):
    package: str = Field(min_length=1, max_length=255)


class UnlockEvent(BaseModel):
    ts: AwareDatetime


class ScreenTimePayload(BaseModel):
    """One upload window from one device."""

    device_id: str = Field(min_length=1, max_length=64)
    schema_version: int = 1
    window_start: AwareDatetime
    window_end: AwareDatetime
    apps: list[AppInfo] = Field(default_factory=list)
    app_sessions: list[AppSession] = Field(default_factory=list)
    screen_sessions: list[Interval] = Field(default_factory=list)
    unlocks: list[UnlockEvent] = Field(default_factory=list)

    @model_validator(mode="after")
    def _window_ordered(self):
        if self.window_end < self.window_start:
            raise ValueError("window_end must not precede window_start")
        return self


def ingest(payload: ScreenTimePayload, conn: Connection) -> IngestResult:
    src = source_id(conn, SOURCE_KEY)
    attrs = Jsonb({"device_id": payload.device_id})

    # Labels the phone sent, plus a fallback so an app we have never seen
    # labelled still gets a row rather than being dropped.
    labels = {a.package: (a.label or a.package) for a in payload.apps}
    for s in payload.app_sessions:
        labels.setdefault(s.package, s.package)

    entity_ids: dict[str, int] = {}
    if labels:
        packages = list(labels)
        conn.execute(
            """
            INSERT INTO health.entities (kind, key, display_name)
            SELECT 'app', k, v FROM unnest(%s::text[], %s::text[]) AS t(k, v)
            ON CONFLICT (kind, key) DO UPDATE
              SET display_name = CASE
                WHEN EXCLUDED.display_name <> EXCLUDED.key THEN EXCLUDED.display_name
                ELSE health.entities.display_name
              END
            """,
            (packages, [labels[p] for p in packages]),
        )
        entity_ids = {
            row[0]: row[1]
            for row in conn.execute(
                "SELECT key, id FROM health.entities WHERE kind = 'app' AND key = ANY(%s)",
                (packages,),
            ).fetchall()
        }

    written = 0

    # App-use intervals. The dedupe key is (package, start), so a session that
    # was still open at the last upload converges when its real end arrives.
    if payload.app_sessions:
        rows = [
            (
                src,
                entity_ids[s.package],
                s.start,
                s.end,
                f"{s.package}@{_ms(s.start)}",
                attrs,
            )
            for s in payload.app_sessions
        ]
        with conn.cursor() as cur:
            cur.executemany(
                """
                INSERT INTO health.sessions
                  (source_id, session_type, entity_id, started_at, ended_at,
                   external_id, attrs)
                VALUES (%s, 'app_use', %s, %s, %s, %s, %s)
                ON CONFLICT (source_id, session_type, external_id) DO UPDATE
                  SET ended_at = EXCLUDED.ended_at
                """,
                rows,
            )
            written += len(rows)

    if payload.screen_sessions:
        rows = [
            (src, s.start, s.end, f"screen@{_ms(s.start)}", attrs)
            for s in payload.screen_sessions
        ]
        with conn.cursor() as cur:
            cur.executemany(
                """
                INSERT INTO health.sessions
                  (source_id, session_type, entity_id, started_at, ended_at,
                   external_id, attrs)
                VALUES (%s, 'screen_on', 0, %s, %s, %s, %s)
                ON CONFLICT (source_id, session_type, external_id) DO UPDATE
                  SET ended_at = EXCLUDED.ended_at
                """,
                rows,
            )
            written += len(rows)

    if payload.unlocks:
        rows = [
            (src, u.ts, f"unlock@{_ms(u.ts)}", attrs)
            for u in payload.unlocks
        ]
        with conn.cursor() as cur:
            cur.executemany(
                """
                INSERT INTO health.raw_events
                  (source_id, event_type, entity_id, ts, external_id, attrs)
                VALUES (%s, 'unlock', 0, %s, %s, %s)
                ON CONFLICT (source_id, event_type, external_id) DO NOTHING
                """,
                rows,
            )
            written += len(rows)

    derived = conn.execute(
        "SELECT health.rebuild_screentime(%s, %s)",
        (payload.window_start, payload.window_end),
    ).fetchone()[0]

    return IngestResult(
        rows_written=written,
        window=(payload.window_start, payload.window_end),
        detail={
            "device_id": payload.device_id,
            "apps": len(labels),
            "app_sessions": len(payload.app_sessions),
            "screen_sessions": len(payload.screen_sessions),
            "unlocks": len(payload.unlocks),
            "derived_observations": derived,
        },
    )


register(
    Adapter(
        key=SOURCE_KEY,
        summary="Per-app foreground sessions, screen-on intervals and unlocks from an Android device",
        model=ScreenTimePayload,
        handler=ingest,
    )
)
