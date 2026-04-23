"""Unified ADK FastAPI runtime for local/GKE/Cloud Run.

This mirrors the reference image style:
  uvicorn <module>:app
where the app is created through `get_fast_api_app(...)` and A2A support is
toggled via the `A2A` environment variable.
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI
from google.adk.cli.fast_api import get_fast_api_app


def _is_truthy(value: str | None) -> bool:
    if value is None:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


TRACE_TO_CLOUD = _is_truthy(os.getenv("TRACE_TO_CLOUD", "false"))
A2A = _is_truthy(os.getenv("A2A", "false"))
SESSION_SERVICE_URI = os.getenv("SESSION_SERVICE_URI", "").strip()
MEMORY_SERVICE_URI = os.getenv("MEMORY_SERVICE_URI", "").strip()

# The root repo folder is the ADK agents_dir so all top-level agent folders
# can be discovered through /list-apps and mounted for integrated A2A routes.
AGENT_DIR = str(Path(__file__).resolve().parent)

_app_kwargs = {
    "agents_dir": AGENT_DIR,
    "allow_origins": ["http://localhost", "http://localhost:8080", "*"],
    "web": True,
    "trace_to_cloud": TRACE_TO_CLOUD,
    "a2a": A2A,
}
if SESSION_SERVICE_URI:
    _app_kwargs["session_service_uri"] = SESSION_SERVICE_URI
if MEMORY_SERVICE_URI:
    _app_kwargs["memory_service_uri"] = MEMORY_SERVICE_URI

app: FastAPI = get_fast_api_app(**_app_kwargs)
