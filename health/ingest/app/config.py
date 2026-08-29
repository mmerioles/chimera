"""Process configuration, read once from the environment."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str
    ingest_token: str
    local_timezone: str
    migrations_dir: str
    run_migrations: bool

    @classmethod
    def from_env(cls) -> "Settings":
        token = os.environ.get("INGEST_TOKEN", "").strip()
        if not token:
            raise RuntimeError(
                "INGEST_TOKEN is required. The ingest endpoint is a write path; "
                "it does not run unauthenticated even on localhost."
            )
        return cls(
            database_url=os.environ.get(
                "DATABASE_URL", "postgresql://health:health@db:5432/health"
            ),
            ingest_token=token,
            local_timezone=os.environ.get("LOCAL_TIMEZONE", "UTC"),
            migrations_dir=os.environ.get("MIGRATIONS_DIR", "/app/migrations"),
            run_migrations=os.environ.get("RUN_MIGRATIONS", "true").lower() == "true",
        )


settings = Settings.from_env()
