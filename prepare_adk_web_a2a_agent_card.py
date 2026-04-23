"""Prepare agent.json for ADK web integrated A2A mode.

`adk web --a2a` discovers A2A apps from subdirectories that contain an
`agent.json` file. This helper writes that file for the selected app using
runtime env vars, so Cloud Run/GKE/local URLs can be injected without baking
environment-specific values into the image.
"""

from __future__ import annotations

import json
import os
from pathlib import Path


def _is_truthy(value: str | None) -> bool:
    if value is None:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _normalize_path_prefix(path_prefix: str) -> str:
    normalized = f"/{path_prefix.strip('/')}"
    if normalized == "/":
        return "/a2a"
    return normalized


def _build_base_url(app_port: str) -> str:
    explicit_base_url = os.environ.get("A2A_CARD_BASE_URL", "").strip().rstrip("/")
    if explicit_base_url:
        return explicit_base_url

    protocol = os.environ.get("A2A_CARD_PROTOCOL", "http").strip() or "http"
    host = os.environ.get("A2A_CARD_HOST", "localhost").strip() or "localhost"
    return f"{protocol}://{host}:{app_port}"


def main() -> None:
    if not _is_truthy(os.environ.get("A2A")):
        return

    app_name = os.environ.get("A2A_AGENT_MODULE", "my_multi_agent").strip()
    if not app_name:
        raise ValueError("A2A_AGENT_MODULE must be a non-empty agent folder name.")

    repo_root = Path(__file__).resolve().parent
    app_dir = repo_root / app_name
    if not app_dir.is_dir():
        raise FileNotFoundError(f"A2A agent folder does not exist: {app_dir}")

    agent_py = app_dir / "agent.py"
    if not agent_py.is_file():
        raise FileNotFoundError(f"Expected agent module file missing: {agent_py}")

    app_port = os.environ.get("APP_PORT", "8000").strip() or "8000"
    base_url = _build_base_url(app_port)
    path_prefix = _normalize_path_prefix(
        os.environ.get("A2A_CARD_PATH_PREFIX", "/a2a")
    )
    rpc_url = f"{base_url}{path_prefix}/{app_name}"

    card = {
        "name": app_name,
        "description": os.environ.get(
            "A2A_CARD_DESCRIPTION", f"A2A endpoint for ADK app '{app_name}'."
        ),
        "version": os.environ.get("A2A_CARD_VERSION", "1.0.0"),
        "url": rpc_url,
        "capabilities": {},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["application/json"],
        "skills": [
            {
                "id": os.environ.get("A2A_CARD_SKILL_ID", app_name),
                "name": os.environ.get("A2A_CARD_SKILL_NAME", app_name),
                "description": os.environ.get(
                    "A2A_CARD_SKILL_DESCRIPTION",
                    f"Interact with ADK app '{app_name}'.",
                ),
                "tags": ["adk", "a2a", app_name],
            }
        ],
    }

    card_path = app_dir / "agent.json"
    card_path.write_text(json.dumps(card, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote integrated A2A card: {card_path} (url={rpc_url})")


if __name__ == "__main__":
    main()
