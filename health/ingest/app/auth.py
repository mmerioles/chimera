"""Bearer-token auth for the write path."""
from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, status

from .config import settings


def require_token(authorization: str = Header(default="")) -> None:
    """Constant-time bearer check.

    Even behind Tailscale this stays on: a tailnet is a network boundary, not
    an authorization boundary, and every device on it would otherwise be able
    to write to the health record.
    """
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(token, settings.ingest_token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
