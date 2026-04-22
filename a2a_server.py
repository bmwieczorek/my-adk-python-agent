"""A2A (Agent-to-Agent) server for ADK agents.

Wraps an ADK agent as an A2A-compliant JSONRPC service so it can be
registered with IBM ContextForge, Gemini Enterprise, or any other
A2A-compatible agent registry.

Which agent is served is controlled by the A2A_AGENT_MODULE env var
(folder name only — the `.agent` suffix is appended automatically):

    A2A_AGENT_MODULE=my_multi_agent    (default)
    A2A_AGENT_MODULE=my_upgrade_agent

The module must export a ``root_agent`` attribute.

Run locally:
    # Default (my_multi_agent):
    uvicorn a2a_server:app --host 0.0.0.0 --port 8000

    # my_upgrade_agent:
    A2A_AGENT_MODULE=my_upgrade_agent uvicorn a2a_server:app --host 0.0.0.0 --port 8000

    # With Cloud Trace + Cloud Logging export (mirrors adk web --otel_to_cloud):
    OTEL_TO_CLOUD=true uvicorn a2a_server:app --host 0.0.0.0 --port 8000

Endpoints served:
    POST /            — A2A JSONRPC endpoint (message/send, message/sendStream)
    GET  /.well-known/agent-card.json — A2A Agent Card (discovery metadata)
"""

import importlib
import logging
import os

from google.adk.a2a.utils.agent_to_a2a import to_a2a

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

_logger = logging.getLogger(__name__)


def _setup_gcp_telemetry() -> None:
    """Mirror the OTel-to-Cloud setup that `adk web --otel_to_cloud` performs.

    Exports traces to Cloud Trace and logs to Cloud Logging using the same
    ADK-internal telemetry helpers, so both the ADK web container and the A2A
    container emit signals to the same GCP backends.
    Cloud Metrics export is intentionally disabled — ADK disables it too due to
    known shutdown errors.
    """
    from google.adk.telemetry.google_cloud import get_gcp_exporters, get_gcp_resource
    from google.adk.telemetry.setup import maybe_set_otel_providers

    maybe_set_otel_providers(
        otel_hooks_to_setup=[
            get_gcp_exporters(
                enable_cloud_tracing=True,
                enable_cloud_metrics=False,
                enable_cloud_logging=True,
            )
        ],
        otel_resource=get_gcp_resource(),
    )
    _logger.info("OTel GCP exporters configured (Cloud Trace + Cloud Logging).")


if os.environ.get("OTEL_TO_CLOUD", "").strip().lower() in ("1", "true", "yes", "on"):
    try:
        _setup_gcp_telemetry()
    except Exception as exc:  # noqa: BLE001
        _logger.warning("OTEL_TO_CLOUD=true but GCP telemetry setup failed: %s", exc)

A2A_AGENT_MODULE = os.environ.get("A2A_AGENT_MODULE", "my_multi_agent")
A2A_HOST = os.environ.get("A2A_HOST", "0.0.0.0")
A2A_PORT = int(os.environ.get("A2A_PORT", "8000"))
A2A_PROTOCOL = os.environ.get("A2A_PROTOCOL", "http")

_module_path = f"{A2A_AGENT_MODULE}.agent"
_module = importlib.import_module(_module_path)
root_agent = getattr(_module, "root_agent")
_logger.info("Serving agent '%s' from module '%s'", root_agent.name, _module_path)

app = to_a2a(
    root_agent,
    host=A2A_HOST,
    port=A2A_PORT,
    protocol=A2A_PROTOCOL,
)
