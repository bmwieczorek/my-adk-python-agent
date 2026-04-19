"""A2A (Agent-to-Agent) server for ADK agents.

Wraps an ADK agent as an A2A-compliant JSONRPC service so it can be
registered with IBM ContextForge, Gemini Enterprise, or any other
A2A-compatible agent registry.

Which agent is served is controlled by the A2A_AGENT_MODULE env var:

    A2A_AGENT_MODULE=my_upgrade_agent.agent    (default)
    A2A_AGENT_MODULE=bartek_adk_agent.agent

The module must export a ``root_agent`` attribute.

Run locally:
    # Default (my_upgrade_agent):
    uvicorn a2a_server:app --host 0.0.0.0 --port 8000

    # bartek_adk_agent:
    A2A_AGENT_MODULE=bartek_adk_agent.agent uvicorn a2a_server:app --host 0.0.0.0 --port 8000

Endpoints served:
    POST /            — A2A JSONRPC endpoint (message/send, message/sendStream)
    GET  /.well-known/agent.json — A2A Agent Card (discovery metadata)
"""

import importlib
import logging
import os

from google.adk.a2a.utils.agent_to_a2a import to_a2a

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)

A2A_AGENT_MODULE = os.environ.get("A2A_AGENT_MODULE", "my_upgrade_agent.agent")
A2A_HOST = os.environ.get("A2A_HOST", "0.0.0.0")
A2A_PORT = int(os.environ.get("A2A_PORT", "8000"))
A2A_PROTOCOL = os.environ.get("A2A_PROTOCOL", "http")

_module = importlib.import_module(A2A_AGENT_MODULE)
root_agent = getattr(_module, "root_agent")
logging.getLogger(__name__).info(
    "Serving agent '%s' from module '%s'", root_agent.name, A2A_AGENT_MODULE
)

app = to_a2a(
    root_agent,
    host=A2A_HOST,
    port=A2A_PORT,
    protocol=A2A_PROTOCOL,
)
