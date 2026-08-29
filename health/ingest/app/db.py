"""Connection pool and schema migration."""
from __future__ import annotations

import hashlib
import logging
import pathlib

from psycopg_pool import ConnectionPool

from .config import settings

log = logging.getLogger(__name__)

pool = ConnectionPool(settings.database_url, min_size=1, max_size=8, open=False)

_MIGRATION_TABLE = """
CREATE SCHEMA IF NOT EXISTS health;
CREATE TABLE IF NOT EXISTS health.schema_migrations (
  filename   text PRIMARY KEY,
  sha256     text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
"""


def run_migrations() -> list[str]:
    """Apply any .sql file in the migrations dir that has not been applied.

    Each file runs in its own transaction. A file whose contents changed after
    being applied raises rather than silently diverging - migrations are
    append-only, edit by adding a new file.
    """
    directory = pathlib.Path(settings.migrations_dir)
    files = sorted(directory.glob("*.sql"))
    applied: list[str] = []

    with pool.connection() as conn:
        conn.execute(_MIGRATION_TABLE)
        conn.commit()
        seen = {
            row[0]: row[1]
            for row in conn.execute(
                "SELECT filename, sha256 FROM health.schema_migrations"
            ).fetchall()
        }

    for path in files:
        body = path.read_text()
        digest = hashlib.sha256(body.encode()).hexdigest()

        if path.name in seen:
            if seen[path.name] != digest:
                raise RuntimeError(
                    f"Migration {path.name} was modified after it was applied "
                    f"(recorded {seen[path.name][:12]}, now {digest[:12]}). "
                    "Add a new migration instead of editing an applied one."
                )
            continue

        log.info("applying migration %s", path.name)
        with pool.connection() as conn:
            conn.execute(body)
            conn.execute(
                "INSERT INTO health.schema_migrations (filename, sha256) VALUES (%s, %s)",
                (path.name, digest),
            )
            conn.commit()
        applied.append(path.name)

    return applied


def apply_runtime_config() -> None:
    """Push env-derived settings into health.config so SQL can see them."""
    with pool.connection() as conn:
        conn.execute(
            """
            INSERT INTO health.config (key, value) VALUES ('local_timezone', %s)
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
            """,
            (settings.local_timezone,),
        )
        conn.commit()


def ensure_readonly_role() -> None:
    """Create/refresh the role Grafana reads through.

    Grafana gets SELECT and nothing else. Dashboards are untrusted input in the
    sense that matters here: a bad panel query, or anyone who reaches the
    Grafana UI, must not be able to mutate the health record. Done in Python
    rather than a migration so the password comes from the environment instead
    of being committed in a .sql file.
    """
    import os

    from psycopg import sql

    role = os.environ.get("GRAFANA_DB_USER", "").strip()
    password = os.environ.get("GRAFANA_DB_PASSWORD", "").strip()
    if not role or not password:
        log.info("no GRAFANA_DB_USER/PASSWORD set; skipping read-only role setup")
        return

    ident = sql.Identifier(role)
    with pool.connection() as conn:
        exists = conn.execute(
            "SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)
        ).fetchone()
        if not exists:
            conn.execute(sql.SQL("CREATE ROLE {} LOGIN").format(ident))

        conn.execute(
            sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(
                ident, sql.Literal(password)
            )
        )
        conn.execute(
            sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                sql.Identifier(conn.info.dbname), ident
            )
        )
        conn.execute(sql.SQL("GRANT USAGE ON SCHEMA health TO {}").format(ident))
        conn.execute(
            sql.SQL("GRANT SELECT ON ALL TABLES IN SCHEMA health TO {}").format(ident)
        )
        conn.execute(
            sql.SQL(
                "ALTER DEFAULT PRIVILEGES IN SCHEMA health "
                "GRANT SELECT ON TABLES TO {}"
            ).format(ident)
        )
        # Postgres grants EXECUTE to PUBLIC by default; the rebuild functions
        # are a write path and should not be in the read-only role's reach.
        for fn in ("health.rebuild_screentime(timestamptz, timestamptz)",
                   "health.upsert_entity(text, text, text)"):
            conn.execute(sql.SQL("REVOKE EXECUTE ON FUNCTION " + fn + " FROM PUBLIC"))
        conn.commit()

    log.info("read-only role %s ensured", role)
