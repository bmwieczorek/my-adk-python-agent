# MacOS setup

## Prerequisites

```bash
brew install --cask visual-studio-code
brew install --cask podman-desktop
brew install podman
brew tap slp/krun
brew install krunkit
```

> **Note:** In podman-desktop: Settings → Create new machine → 6 CPU, 6 GB, 50 GB, Provider Type: Apple HyperVisor, Start machine now: disabled

## Docker wrapper for Podman

Add to `.bash_profile`:

```bash
export PATH="~/apps/docker/bin:$PATH"
```

Create `~/apps/docker/bin/docker`:

```bash
#!/bin/bash
# Local wrapper: map docker commands to podman
if [ "$1" = "build" ]; then
  shift
  exec podman build --format docker "$@"
else
  exec podman "$@"
fi
```

## Virtual Environment Setup

### IntelliJ double brackets in terminal with pyenv virtualenv

When switching the Python interpreter in IntelliJ to a pyenv virtualenv (e.g. `agents-3.12.13`), the terminal may show
double brackets like `((agents-3.12.13))` in the prompt, while other virtualenvs (e.g. `composer-2.4.3-airflow-2.5.3-python-3.8.20-jupyter`)
show single brackets correctly.

**Root cause:**

The newer Python versions (3.12+) generate `activate` scripts that set a `VIRTUAL_ENV_PROMPT` variable and prepend it to `PS1`:

```bash
VIRTUAL_ENV_PROMPT='(agents-3.12.13) '
PS1="${VIRTUAL_ENV_PROMPT}${PS1:-}"
```

IntelliJ also detects the virtualenv and prepends its own `(agents-3.12.13) ` prefix to `PS1`, resulting in double brackets.

The older Python versions (3.8) generate `activate` scripts that directly set `PS1` without `VIRTUAL_ENV_PROMPT`:

```bash
PS1="(composer-2.4.3-airflow-2.5.3-python-3.8.20-jupyter) ${PS1:-}"
```

IntelliJ sees the prompt is already modified and does not add a second prefix, so no double brackets.

**Fix options:**

1. **In IntelliJ:** Settings → Tools → Terminal → uncheck **"Activate virtualenv"** to prevent IntelliJ from adding its own prefix.
2. **Set `VIRTUAL_ENV_DISABLE_PROMPT=1`** in `.bash_profile` before pyenv/virtualenv init, so the `activate` script skips `PS1` modification
   and only IntelliJ adds the prefix.
3. **Fix the `activate` script directly** (applied fix):

   ```diff
   diff activate.orig activate:
   < PS1="("'(agents-3.12.13) '") ${PS1:-}"
   > PS1="${VIRTUAL_ENV_PROMPT}${PS1:-}"
   ```

   Restored `activate` back to the original Python-generated line: `PS1="${VIRTUAL_ENV_PROMPT}${PS1:-}"`  
   This uses `VIRTUAL_ENV_PROMPT` which already has the correct format `'(agents-3.12.13) '`, so no extra wrapping is needed.

## Python Dependencies

There are two separate sets of requirements:

| File                                                 | Purpose                                                                                         |
|------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `requirements-docker.in` → `requirements-docker.txt` | Lean deps for running in Docker/Podman (`adk web` / A2A) — `google-adk` + `pendulum` + `a2a-sdk` |
| `requirements.in` → `requirements.txt`               | Full deps for Vertex AI Agent Engine deployment (`deploy.py`, `delete.py`, `api.py`, `rest.py`)   |

Install `pip-tools` (one-time setup):

```bash
pip install pip-tools
```

Compile pinned requirements from `.in` files:

```bash
pip-compile requirements-docker.in
pip-compile requirements.in
```

> **Tip:** `pip-compile` can be slow for large dependency trees (e.g. `google-cloud-aiplatform`).
> Use verbose mode to see progress in real time:
>
> ```bash
> pip-compile -v requirements.in
> ```
>
> To stop it, press `Ctrl+C`. This is safe — it only aborts the resolver; no files are written until it finishes successfully.

Upgrade all packages to their latest compatible versions:

```bash
pip-compile --upgrade requirements-docker.in
pip-compile --upgrade -v requirements.in
```

Install/sync the pinned dependencies into the current environment:

```bash
pip-sync requirements.txt
```

Show currently installed versions of key packages:

```bash
pip show google-cloud-aiplatform google-genai google-adk
```

List outdated packages:

```bash
pip list --outdated
```

## Build & Run

> **Note:** `--platform=linux/amd64` is set in the Dockerfile. This ensures consistent layer caching on ARM Macs (Apple Silicon).
> **Note:** `GOOGLE_GENAI_USE_VERTEXAI` is configured via Docker build arg; other cloud/application variables are passed at **runtime** (`docker run` / `podman run`).

### Using `deploy_docker.sh` (recommended)

```bash
# Default (ADK web UI, my_upgrade_agent for A2A):
./deploy_docker.sh

# A2A mode with a specific agent:
export SERVE_MODE=a2a A2A_AGENT_MODULE=my_multi_agent
./deploy_docker.sh

# A2A mode with default agent (my_upgrade_agent):
export SERVE_MODE=a2a
./deploy_docker.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVE_MODE` | `adk` | `adk` for ADK dev UI, `a2a` for A2A JSONRPC server |
| `A2A_AGENT_MODULE` | `my_multi_agent` | Agent folder name to serve in A2A mode (`.agent` suffix added automatically) |
| `HOST_PORT` | `8000` | Host port to publish |

> **Important:** use `export` — plain `VAR=x && ./script.sh` does **not** pass vars to the script.

### Manual `docker run`

```bash
docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI=TRUE -t bartek-adk-agent . && docker image prune -f

(docker rm -f bartek-adk-agent 2>/dev/null || true) && \
docker run --name bartek-adk-agent -p 8000:8000 --rm -it \
  -e GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT} \
  -e GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION} \
  -e BIG_QUERY_DATASET_ID=${BIG_QUERY_DATASET_ID} \
  -e GCS_BUCKET=${GCS_BUCKET} \
  -v "$HOME/.config/gcloud/application_default_credentials.json:/tmp/adc.json:ro" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json \
  bartek-adk-agent

```

## A2A (Agent-to-Agent) Protocol Support

The agent can be exposed as an [A2A](https://a2a-protocol.org/)-compliant JSONRPC service,
allowing registration with **IBM ContextForge**, **Gemini Enterprise**, or any
other A2A-compatible agent registry.

### How it works

The Dockerfile supports two serving modes controlled by the `SERVE_MODE` env var:

| `SERVE_MODE` | Entrypoint | Purpose |
|---|---|---|
| `adk` (default) | `adk web --host 0.0.0.0 --otel_to_cloud .` | Standard ADK dev UI — the same behaviour as before |
| `a2a` | `uvicorn a2a_server:app --host 0.0.0.0 --port 8000` | A2A JSONRPC server for agent-to-agent communication |

The A2A mode is implemented via Google ADK's built-in
[`to_a2a()`](https://github.com/google/adk-python/blob/main/src/google/adk/a2a/utils/agent_to_a2a.py)
utility (`google.adk.a2a.utils.agent_to_a2a`), which wraps the existing
`root_agent` as a Starlette/ASGI application. It:

- Serves an **Agent Card** at `GET /.well-known/agent-card.json` — the standard A2A
  discovery endpoint. The card is **auto-generated** from the agent's `name`,
  `description`, `instruction`, and `tools` (including `get_currency_rate` and
  `get_current_time`, which are exposed as A2A *skills*).
- Handles A2A JSONRPC calls at `POST /` — supports `message/send` and
  `message/sendStream` methods per the
  [A2A protocol spec v0.3](https://a2a-protocol.org/v0.3.0/specification).
- Manages sessions and task state in-memory via ADK's `InMemorySessionService`
  and the A2A SDK's `InMemoryTaskStore`.

### Files overview

| File | Role |
|---|---|
| `a2a_server.py` | Entry point — calls `to_a2a(root_agent, ...)` to create the Starlette ASGI app |
| `my_multi_agent/agent.py` | Agent definition — `root_agent` with tools and instructions |
| `Dockerfile` | Conditional `CMD` — runs `adk web` or `uvicorn a2a_server:app` based on `SERVE_MODE` |
| `requirements-docker.in` | Adds [`a2a-sdk[http-server]`](https://pypi.org/project/a2a-sdk/) (Starlette server components) |

### Run locally

```bash
# Suppress experimental-feature warnings (optional)
export ADK_SUPPRESS_A2A_EXPERIMENTAL_FEATURE_WARNINGS=1

# Default — serves my_multi_agent:
uvicorn a2a_server:app --host 0.0.0.0 --port 8000

# Serve my_upgrade_agent instead:
A2A_AGENT_MODULE=my_upgrade_agent uvicorn a2a_server:app --host 0.0.0.0 --port 8000
```

Verify the Agent Card:

```bash
curl http://localhost:8000/.well-known/agent-card.json | python3 -m json.tool
```

Send a test message:

```bash
curl -X POST http://localhost:8000/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "test-123",
        "role": "user",
        "parts": [{"kind": "text", "text": "1 usd to pln"}]
      }
    },
    "id": 1
  }'
```

### Run in Docker (A2A mode)

Set `SERVE_MODE=a2a` at runtime to switch from the default ADK dev UI to the
A2A JSONRPC server:

```bash
# Using deploy_docker.sh (recommended):
export SERVE_MODE=a2a
./deploy_docker.sh

# With a specific agent:
export SERVE_MODE=a2a A2A_AGENT_MODULE=my_multi_agent
./deploy_docker.sh
```

Or manually:

```bash
docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI=TRUE -t bartek-adk-agent . && docker image prune -f

(docker rm -f bartek-adk-agent 2>/dev/null || true) && \
docker run --name bartek-adk-agent -p 8000:8000 --rm -it \
  -e SERVE_MODE=a2a \
  -e GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT} \
  -e GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION} \
  -v "$HOME/.config/gcloud/application_default_credentials.json:/tmp/adc.json:ro" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json \
  bartek-adk-agent
```

### IBM ContextForge — local setup & A2A registration

[IBM ContextForge](https://ibm.github.io/mcp-context-forge/) is an open-source
registry and proxy that federates MCP, A2A, and REST/gRPC APIs. You can run it
locally with Podman (or Docker) to test A2A agent registration end-to-end.
See the [ContextForge A2A docs](https://ibm.github.io/mcp-context-forge/using/agents/a2a/) for full details.

#### Networking: `host.containers.internal` vs `localhost`

ContextForge runs **inside a container**. From inside that container `localhost`
refers to the container itself, not your Mac. To reach services running on the
host machine you must use a special DNS name:

| Runtime | Host-reachable DNS name |
|---------|------------------------|
| **Podman** | `host.containers.internal` |
| **Docker** | `host.docker.internal` |

```
┌───────────────────────────────────────────┐
│  Host (your Mac)                          │
│                                           │
│  uvicorn a2a_server:app :8000  ◄───────┐  │
│                                        │  │
│  ┌───────────────────────────────┐     │  │
│  │  Container (Podman/Docker)    │     │  │
│  │  ContextForge :4444           │     │  │
│  │                               │     │  │
│  │  localhost = this container   │     │  │
│  │  host.containers.internal ────┼─────┘  │
│  └───────────────────────────────┘        │
└───────────────────────────────────────────┘
```

#### 1. Start ContextForge with Docker/Podman

```bash
# Create the host file first so Docker mounts it as a file, not a directory
touch ./ibm-context-forge/mcp.db

docker run -d --name mcpgateway \
  -p 4444:4444 \
  -e HOST=0.0.0.0 \
  -e DATABASE_URL=sqlite:///./mcp.db \
  -v $(pwd)/ibm-context-forge/mcp.db:/app/mcp.db \
  -e MCPGATEWAY_UI_ENABLED=true \
  -e MCPGATEWAY_ADMIN_API_ENABLED=true \
  -e MCPGATEWAY_A2A_ENABLED=true \
  -e MCPGATEWAY_A2A_METRICS_ENABLED=true \
  -e MCPGATEWAY_A2A_DEFAULT_TIMEOUT=300 \
  -e MCP_TOOL_CALL_TIMEOUT=300 \
  -e TOOL_TIMEOUT=300 \
  -e MCPGATEWAY_UI_TOOL_TEST_TIMEOUT=300000 \
  -e MCPGATEWAY_A2A_MAX_RETRIES=3 \
  -e SSRF_ALLOW_LOCALHOST=true \
  -e SSRF_ALLOW_PRIVATE_NETWORKS=true \
  -e JWT_SECRET_KEY=my-test-key-but-now-longer-than-32-bytes \
  -e AUTH_REQUIRED=true \
  -e SECURE_COOKIES=false \
  -e PLATFORM_ADMIN_EMAIL=admin@example.com \
  -e PLATFORM_ADMIN_PASSWORD=changeme \
  -e PLATFORM_ADMIN_FULL_NAME="Platform Administrator" \
  ghcr.io/ibm/mcp-context-forge:v1.0.0-RC-3
```

> **Notes:**
> - The image tag is `v1.0.0-RC-3` (with the `v` prefix).
> - `SSRF_ALLOW_LOCALHOST` and `SSRF_ALLOW_PRIVATE_NETWORKS` must be `true` for
>   local testing so ContextForge can reach your agent on the host.
> - The volume mount persists the SQLite DB across container restarts. The host
>   file must exist before starting (`touch` above) — otherwise Docker creates a
>   directory instead.
> - All `*_TIMEOUT` values are in **seconds** except
>   `MCPGATEWAY_UI_TOOL_TEST_TIMEOUT` which is in **milliseconds**.

#### Persisting the SQLite database

By default, `DATABASE_URL=sqlite:///./mcp.db` stores the database **inside
the container** at `/app/mcp.db`. When the container is removed, all
registered agents, tokens, and configuration are lost.

The volume mount `-v $(pwd)/ibm-context-forge/mcp.db:/app/mcp.db` in the
command above handles persistence. To inspect the database on the host:

```bash
sqlite3 ./ibm-context-forge/mcp.db ".tables"
```

Verify it's running:

```bash
curl -s http://localhost:4444/health | python3 -m json.tool
```

Example response (truncated):

```json
{
    "status": "healthy",
    "mcp_runtime": {
        "mode": "python",
        "mounted": "python",
        ...
    }
}
```

Admin UI: <http://localhost:4444/admin>

#### 2. Obtain a JWT bearer token

ContextForge requires JWT authentication. Two options:

**Option A — Login via REST API** (simpler, uses admin credentials):

```bash
MCPGATEWAY_BEARER_TOKEN=$(curl -s -X POST "http://localhost:4444/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"changeme"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
export MCPGATEWAY_BEARER_TOKEN
```

**Option B — Generate locally with PyJWT** (offline, no server call needed):

```bash
pip install pyjwt  # one-time

MCPGATEWAY_BEARER_TOKEN=$(python3 -c "
import jwt, datetime, uuid
token = jwt.encode({
    'sub': 'admin@example.com',
    'exp': datetime.datetime.utcnow() + datetime.timedelta(days=7),
    'iat': datetime.datetime.utcnow(),
    'jti': str(uuid.uuid4()),
    'iss': 'mcpgateway',
    'aud': 'mcpgateway-api'
}, 'my-test-key-but-now-longer-than-32-bytes', algorithm='HS256')
print(token)
")
export MCPGATEWAY_BEARER_TOKEN
```

> **Note:** Option B requires knowing the `JWT_SECRET_KEY` you passed to the
> container. The email/password in Option A must match `PLATFORM_ADMIN_EMAIL`
> and `PLATFORM_ADMIN_PASSWORD`.

#### 3. Start your A2A agent

In a separate terminal:

```bash
export A2A_AGENT_MODULE=my_multi_agent
uvicorn a2a_server:app --host 0.0.0.0 --port 8000
```

#### 4. Register the agent with ContextForge

##### ContextForge agent types

ContextForge supports four agent types. The type determines how ContextForge
formats and forwards requests to the agent:

| Agent Type | Protocol | Endpoint Example | Request Format | When to Use |
|---|---|---|---|---|
| **`jsonrpc`** (or `generic`) | A2A JSONRPC | `http://agent:8000/` | JSON-RPC 2.0 envelope (`{"jsonrpc":"2.0","method":"SendMessage",...}`) | **A2A-compliant agents** — Google ADK `to_a2a()`, A2A SDK samples. **This is what we use.** |
| **`openai`** | OpenAI Chat Completions | `https://api.openai.com/v1/chat/completions` | OpenAI format (`messages`, `model`, etc.) | Direct OpenAI API or any **OpenAI-compatible** endpoint (Azure OpenAI, vLLM, Ollama, LiteLLM) |
| **`anthropic`** | Anthropic Messages | `https://api.anthropic.com/v1/messages` | Anthropic format (`messages`, `model`, etc.) | Direct **Anthropic API** or Anthropic-compatible endpoints |
| **`custom`** | Any REST | `https://your-agent.com/api` | Wrapped as `{"interaction_type":"...","parameters":{...}}` — **no** JSON-RPC | Non-standard REST agents with custom APIs. Supports `capabilities` and `config` fields. |

> **Key difference:** `jsonrpc`/`generic` agents receive a standard JSON-RPC 2.0
> request. All other types (`openai`, `anthropic`, `custom`) receive a
> ContextForge-wrapped payload without a JSON-RPC envelope.

The curl command below explicitly sets `"agent_type": "jsonrpc"` because our
ADK agent uses `to_a2a()` which produces a standard A2A JSON-RPC server.
Note: there is no default — `agent_type` is a required field.

```bash
curl -X POST "http://localhost:4444/a2a" \
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent": {
      "name": "bartek_currency_converter_agent",
      "endpoint_url": "http://host.containers.internal:8000/",
      "agent_type": "jsonrpc",
      "description": "Currency converter agent — converts currencies using live FX rates",
      "auth_type": "bearer",
      "auth_token": "dummy"
    }
  }'
```

Example response:

```json
{
  "id": "6f0de5c225914cf09c4fcccb8575370c",
  "name": "bartek_currency_converter_agent",
  "slug": "bartek-currency-converter-agent",
  "description": "Currency converter agent",
  "endpointUrl": "http://host.containers.internal:8000/",
  "agentType": "jsonrpc",
  "protocolVersion": "1.0",
  "enabled": true,
  "reachable": true,
  "createdAt": "2026-04-19T12:28:13.484596",
  "visibility": "public"
}
```

> **Notes:**
> - Use `host.containers.internal` (Podman) or `host.docker.internal` (Docker)
>   — **not** `localhost` — so the container can reach your host.
> - `auth_type` must be one of: `basic`, `bearer`, `oauth`, `authheaders`,
>   `query_param` (there is no `none`). Use `bearer` with a dummy token if your
>   agent doesn't require auth.
> - The payload must be wrapped in an `"agent"` key.

You can also register via the Admin UI → **A2A Agents** tab.

##### Authentication flow

There are two levels of auth in the ContextForge → Agent flow:

| Hop | Auth Type | Value | Purpose |
|-----|-----------|-------|---------|
| Client → ContextForge | JWT Bearer | `$MCPGATEWAY_BEARER_TOKEN` | Authenticate to ContextForge API (required for all requests) |
| ContextForge → Agent | Bearer | `"dummy"` | Required by ContextForge registration, but our agent ignores it |

The `Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN` header on every curl
command authenticates **you** to ContextForge. The `"auth_type": "bearer",
"auth_token": "dummy"` in the registration payload is what ContextForge sends
**to your agent** when proxying requests — our agent currently doesn't check it.

> **⚠️ Our agent is currently unauthenticated.** Anyone who can reach
> `http://localhost:8000/` can call it directly without a token. ContextForge
> only protects the gateway layer, not the agent itself.

##### Securing the agent (future options)

To add auth to the agent itself:

| Option | How | Pros | Cons |
|--------|-----|------|------|
| **Network-level** | Bind agent to `127.0.0.1` only; let only ContextForge (on same host) reach it. In K8s use NetworkPolicy. | Simple, no code changes | Only works for co-located deployments |
| **Middleware bearer token** | Add Starlette/FastAPI middleware to `a2a_server.py` that validates `Authorization: Bearer <token>`. Update ContextForge registration with the real token. | Standard approach, easy to implement | Must manage and rotate tokens |
| **OAuth 2.0 / OIDC** | Use an identity provider (e.g. Keycloak, Auth0). Agent validates JWTs from the IdP. Register with `"auth_type": "oauth"` in ContextForge. | Production-grade, centralized identity | More complex setup |
| **mTLS** | Require client TLS certificates. Both ContextForge and the agent present certs to each other. | Strongest transport-level security | Certificate management overhead |
| **API gateway** | Place the agent behind an API gateway (e.g. Envoy, Kong, GCP API Gateway) that handles auth, rate limiting, and TLS termination. | Decouples auth from agent code | Additional infrastructure |

##### Example: middleware bearer token implementation

The simplest approach — generate a shared secret and validate it in the agent:

**1. Generate a token** (static API key):

```bash
# Generate a random 32-byte hex token
openssl rand -hex 32
# e.g.: a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2
```

Or a self-signed JWT (with expiry):

```bash
python3 -c "
import jwt, datetime, uuid
secret = '$(openssl rand -hex 32)'
token = jwt.encode({
    'sub': 'contextforge',
    'exp': datetime.datetime.utcnow() + datetime.timedelta(days=365),
    'jti': str(uuid.uuid4())
}, secret, algorithm='HS256')
print(f'AGENT_JWT_SECRET={secret}')
print(f'AGENT_API_TOKEN={token}')
"
```

**2. Add middleware to `a2a_server.py`** that checks the token:

```python
import os
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

AGENT_API_TOKEN = os.environ.get("AGENT_API_TOKEN")

class BearerAuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if AGENT_API_TOKEN:
            auth = request.headers.get("Authorization", "")
            if auth != f"Bearer {AGENT_API_TOKEN}":
                return JSONResponse({"error": "Unauthorized"}, status_code=401)
        return await call_next(request)

# app.add_middleware(BearerAuthMiddleware)  # uncomment to enable
```

**3. Start the agent with the token:**

```bash
export AGENT_API_TOKEN=a1b2c3d4e5f6...
uvicorn a2a_server:app --host 0.0.0.0 --port 8000
```

**4. Update ContextForge registration** with the real token:

```bash
curl -X POST "http://localhost:4444/a2a" \
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent": {
      "name": "bartek_currency_converter_agent",
      "endpoint_url": "http://host.containers.internal:8000/",
      "agent_type": "jsonrpc",
      "description": "Currency converter agent",
      "auth_type": "bearer",
      "auth_token": "a1b2c3d4e5f6..."
    }
  }'
```

ContextForge will now send `Authorization: Bearer a1b2c3d4e5f6...` to your
agent on every invocation, and the middleware will validate it.

| Token Approach | How to Generate | Rotation | Complexity |
|----------------|----------------|----------|------------|
| **Static API key** | `openssl rand -hex 32` | Manual — regenerate & update ContextForge | Simplest |
| **Self-signed JWT** | PyJWT + a secret, set expiry | Regenerate when expired | Moderate |
| **OAuth / IdP** | Issued by Keycloak, Auth0, etc. | Automatic via refresh tokens | Production-grade |

#### 5. Test the agent through ContextForge (A2A)

The A2A invoke endpoint proxies your request through ContextForge to the agent:

```
Client ──POST /a2a/{name}/invoke──▶ ContextForge :4444 ──A2A JSONRPC──▶ Agent :8000
                                     (A2A gateway)                      (uvicorn a2a_server)
```

```bash
curl -X POST "http://localhost:4444/a2a/bartek_currency_converter_agent/invoke" \
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "parameters": {
      "method": "message/send",
      "params": {
        "message": {
          "messageId": "test-123",
          "role": "user",
          "parts": [{"kind": "text", "text": "1 USD to PLN"}]
        }
      }
    }
  }'
```

Example response (abbreviated):

```json
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": {
    "artifacts": [
      {
        "artifactId": "9dab87d7-f08a-47cf-81b4-e55a3684e98d",
        "parts": [{"kind": "text", "text": "2026-04-19 15:43:19 - 1 USD is 3.5936406352 PLN"}]
      }
    ],
    "id": "c0ce263a-6f05-417f-b586-fad13c9a636e",
    "kind": "task",
    "status": {"state": "completed", "timestamp": "2026-04-19T15:43:23.261175+00:00"}
  }
}
```

#### 6. Use the agent via MCP protocol

ContextForge automatically exposes registered A2A agents as MCP tools.
The MCP `tools/call` request goes through ContextForge which translates it to
A2A JSONRPC and forwards to your agent:

```
Client ──MCP tools/call──▶ ContextForge :4444 ──A2A JSONRPC──▶ Agent :8000
            (POST /rpc)     (MCP→A2A bridge)                    (uvicorn a2a_server)
```

List available tools and call your agent via the standard MCP `tools/call` method:

```bash
# List MCP tools (your A2A agent appears automatically)
curl -s -X POST "http://localhost:4444/rpc" \
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "tools/list", "id": 1}' | jq
```

Example response:

```json
{
  "jsonrpc": "2.0",
  "result": {
    "tools": [
      {
        "name": "a2a-bartek-currency-converter-agent",
        "description": "A2A Agent: Currency converter agent",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": {"type": "string", "description": "User query"}
          },
          "required": ["query"]
        },
        "annotations": {
          "title": "A2A Agent: bartek_currency_converter_agent",
          "a2a_agent_id": "6f0de5c225914cf09c4fcccb8575370c",
          "a2a_agent_type": "jsonrpc"
        }
      }
    ]
  },
  "id": 1
}
```

```bash
# Call the agent via MCP
curl -s -X POST "http://localhost:4444/rpc" \
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {
      "name": "a2a-bartek-currency-converter-agent",
      "arguments": {"query": "1 USD to PLN"}
    },
    "id": 1
  }' | jq '.result.content[0].text | fromjson'
```

Example response:

```json
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": {
    "artifacts": [
      {
        "artifactId": "5b48b307-75d3-4853-8a7e-a32de5f4b563",
        "parts": [
          {"kind": "text", "text": "2026-04-19 17:25:10 - 1 USD is 3.593640642 PLN"}
        ]
      }
    ],
    "contextId": "32550651-02b7-4e7c-9692-e715258c04fd",
    "history": [
      {"kind": "message", "role": "user", "parts": [{"kind": "text", "text": "1 USD to PLN"}]},
      {"kind": "message", "role": "agent", "parts": [{"data": {"name": "get_currency_rate", "args": {"from_currency": "USD", "to_currency": "PLN"}}, "kind": "data", "metadata": {"adk_type": "function_call"}}]},
      {"kind": "message", "role": "agent", "parts": [{"data": {"name": "get_currency_rate", "response": {"status": "success", "rate": 3.593640642}}, "kind": "data", "metadata": {"adk_type": "function_response"}}]},
      {"kind": "message", "role": "agent", "parts": [{"data": {"name": "get_current_time", "args": {}}, "kind": "data", "metadata": {"adk_type": "function_call"}}]},
      {"kind": "message", "role": "agent", "parts": [{"data": {"name": "get_current_time", "response": {"status": "success", "current_datetime": "2026-04-19 17:25:10"}}, "kind": "data", "metadata": {"adk_type": "function_response"}}]},
      {"kind": "message", "role": "agent", "parts": [{"kind": "text", "text": "2026-04-19 17:25:10 - 1 USD is 3.593640642 PLN"}]}
    ],
    "id": "b61a68fe-ae1b-4420-a39b-0990e2027f12",
    "kind": "task",
    "metadata": {
      "adk_app_name": "bartek_currency_converter_agent_latest",
      "adk_usage_metadata": {
        "candidatesTokenCount": 37,
        "promptTokenCount": 281,
        "totalTokenCount": 318,
        "trafficType": "ON_DEMAND"
      }
    },
    "status": {"state": "completed", "timestamp": "2026-04-19T17:25:12.847208+00:00"}
  }
}
```

```bash
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {
      "name": "a2a-bartek-currency-converter-agent",
      "arguments": {"query": "1 USD to PLN"}
    },
    "id": 1
  }' | jq -r '.result.content[0].text | fromjson | .result.artifacts[0].parts[0].text'
# Output: 2026-04-19 17:25:10 - 1 USD is 3.593640642 PLN
```

> **Note:** The MCP response wraps the A2A JSON as an escaped string inside
> `result.content[0].text`. Use `jq`'s `fromjson` filter to parse it.

#### 7. Manage registered agents

```bash
# List all agents
curl -s "http://localhost:4444/a2a" \
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" | jq
```

Example response:

```json
[
  {
    "id": "6f0de5c225914cf09c4fcccb8575370c",
    "name": "bartek_currency_converter_agent",
    "slug": "bartek-currency-converter-agent",
    "enabled": true,
    "reachable": true,
    "agentType": "jsonrpc",
    "endpointUrl": "http://host.containers.internal:8000/"
  }
]
```

```bash
# Delete an agent (use the id from registration response)
curl -X DELETE "http://localhost:4444/a2a/<agent-id>" \
  -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN"
```

Example response:

```json
{"status": "success", "message": "A2A Agent <agent-id> deleted successfully"}
```

#### 8. View ContextForge logs

```bash
# Stream all logs (follow mode)
docker logs -f mcpgateway

# Last 100 lines
docker logs --tail 100 mcpgateway

  # Logs since a specific time
docker logs --since 5m mcpgateway
```

#### 9. Cleanup

```bash
podman rm -f mcpgateway
```

> **Tip:** The SQLite DB is ephemeral (inside the container) by default. After
> restarting ContextForge you need to generate a new token and re-register
> agents. See [Persisting the SQLite database](#persisting-the-sqlite-database)
> to mount the DB file on the host.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVE_MODE` | `adk` | `adk` for ADK dev UI, `a2a` for A2A JSONRPC server |
| `A2A_AGENT_MODULE` | `my_multi_agent` | Agent folder name to serve in A2A mode (`.agent` suffix added automatically by `a2a_server.py`) |
| `A2A_HOST` | `0.0.0.0` | Bind host for the A2A server |
| `A2A_PORT` | `8000` | Bind port for the A2A server |
| `A2A_PROTOCOL` | `http` | Protocol advertised in the Agent Card URL |
| `ADK_SUPPRESS_A2A_EXPERIMENTAL_FEATURE_WARNINGS` | *(unset)* | Set to `1` to suppress ADK A2A experimental warnings |

## Deploy to GKE

Quick path (script):

```bash
chmod +x ./deploy_gke.sh

export GOOGLE_CLOUD_PROJECT=...
export GOOGLE_CLOUD_LOCATION=...
export BIG_QUERY_DATASET_ID=...
export GCS_BUCKET=...

export GKE_NAMESPACE=...
export GKE_CLUSTER_PROJECT=...
export GKE_CLUSTER_NAME=...
export GKE_CLUSTER_REGION=...
export AGENT_IMAGE_REPO=...
export GKE_SERVICE_ACCOUNT=...             # GCP SA email (e.g. name@project.iam.gserviceaccount.com); K8s SA name is derived as part before '@'
export GKE_HTTP_URL_DOMAIN=...             # e.g. example.com


./deploy_gke.sh
```

#### Image tag auto-increment

The script automatically detects the current image tag from the running
deployment and bumps the patch version:

```bash
# Auto-bump: queries running pod, e.g. 0.0.7 → deploys 0.0.8
./deploy_gke.sh

# Explicit tag: skips auto-detection
./deploy_gke.sh 1.0.0
```

If no existing deployment is found, the script defaults to `0.0.1`.

To check the current image tag of the running pod:

```bash
kubectl get pod -n ${GKE_NAMESPACE} -l app=bartek-adk-agent \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

You can put these exports in `.bash_profile` and open a new terminal before running the script.

The script expects `GCS_BUCKET` directly.

#### A2A agent selection

The script scans the repo for agent folders containing a `root_agent`
definition and presents an interactive picker:

```
Scanning for available root agents...

Option #     Agent folder
--------     ----------------------------------------
1            my_bq_agent
2            my_multi_agent
3            my_upgrade_agent

Select the agent to expose via A2A (Option #): 2
Selected: my_multi_agent
```

The `.agent` suffix is appended automatically (e.g. `my_multi_agent` →
`my_multi_agent.agent`).

To skip the interactive picker, set `A2A_AGENT_MODULE` before running:

```bash
A2A_AGENT_MODULE=my_multi_agent ./deploy_gke.sh
```

### 1. Authenticate with GCP and GKE

```bash
gcloud auth login
gcloud config set project ${GOOGLE_CLOUD_PROJECT}
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --region ${GKE_CLUSTER_REGION} --project ${GKE_CLUSTER_PROJECT}
```

### 2. Build, tag, and push the image to the registry

```bash
docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI=TRUE -t bartek-adk-agent . && docker image prune -f
docker tag bartek-adk-agent ${AGENT_IMAGE_REPO}:0.0.3
docker push ${AGENT_IMAGE_REPO}:0.0.3
```

### 3. Create the namespace (if it doesn't exist)

```bash
kubectl create namespace ${GKE_NAMESPACE}
```

### 4. Deploy to the specific namespace

Traffic flow between browser/agent and pod:

```
Browser → Istio Gateway → VirtualService → Service (ClusterIP, port 8000) → Pod (adk-web container)
A2A Client → Istio Gateway → VirtualService → Service (ClusterIP, port 8001) → Pod (a2a container)
```

#### Sidecar architecture

A single pod runs **two containers** (sidecar pattern) from the same Docker
image, each with a different `SERVE_MODE` and port:

| Container | SERVE_MODE | Port | Purpose |
|-----------|------------|------|---------|
| `adk-web` | `adk` | 8000 | ADK dev web UI for human interaction |
| `a2a` | `a2a` | 8001 | A2A JSONRPC server for agent-to-agent communication |

```
┌─── Pod (1 replica) ───────────────────────────────────┐
│                                                       │
│  ┌─── adk-web container ────┐  ┌─── a2a container ──┐ │
│  │ SERVE_MODE=adk           │  │ SERVE_MODE=a2a     │ │
│  │ APP_PORT=8000            │  │ APP_PORT=8001      │ │
│  │ Health: GET /            │  │ Health: GET        │ │
│  │                          │  │ /.well-known/      │ │
│  │ adk web --port 8000      │  │ agent-card.json    │ │
│  │   --no-reload            │  │                    │ │
│  │   --otel_to_cloud        │  │ uvicorn :8001      │ │
│  └──────────────────────────┘  └────────────────────┘ │
│         ▲                             ▲               │
└─────────┼─────────────────────────────┼───────────────┘
          │                             │
    Service :8000                 Service :8001
    (http-web)                    (http-a2a)
          │                             │
    VirtualService              VirtualService
    host: bartek-adk-agent-*    host: bartek-adk-agent-a2a-*
```

Both containers share the same GCP config (Workload Identity, runtime env
vars) but are independently health-checked. If either container fails, the
pod becomes unready — this is an accepted trade-off of the sidecar pattern
vs. two separate deployments.

Kubernetes resources overview:

| Resource           | File                       | Purpose                                                        |
|--------------------|----------------------------|----------------------------------------------------------------|
| **Deployment**     | `k8s/deployment.yaml`      | Runs the pod                                                   |
| **Service**        | `k8s/service.yaml`         | Gives the pod a stable ClusterIP + DNS name inside the cluster |
| **VirtualService** | `k8s/virtual-service.yaml` | Routes external traffic from the Istio gateway to the Service  |

```bash
# deployment.yaml uses ${GKE_SERVICE_ACCOUNT_NAME} and ${AGENT_IMAGE_URI} placeholders,
# service.yaml uses ${GKE_NAMESPACE} —
# envsubst resolves them from environment variables before piping to kubectl.
# envsubst is a standard GNU gettext utility (available on macOS and Linux). It reads stdin, replaces ${VAR} references with their environment variable values, and writes to stdout
envsubst < k8s/deployment.yaml | kubectl apply -n ${GKE_NAMESPACE} -f -
envsubst < k8s/service.yaml | kubectl apply -n ${GKE_NAMESPACE} -f -
envsubst < k8s/virtual-service.yaml | kubectl apply -n ${GKE_NAMESPACE} -f -

# Runtime values passed to both containers via kubectl set env
export GOOGLE_CLOUD_PROJECT=...
export GOOGLE_CLOUD_LOCATION=...
export BIG_QUERY_DATASET_ID=...
export GCS_BUCKET=...

for container in adk-web a2a; do
  kubectl set env deployment/bartek-adk-agent -n ${GKE_NAMESPACE} -c ${container} \
    GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT}" \
    GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION}" \
    BIG_QUERY_DATASET_ID="${BIG_QUERY_DATASET_ID}" \
    GCS_BUCKET="${GCS_BUCKET}"
done

kubectl rollout status deployment/bartek-adk-agent -n ${GKE_NAMESPACE}
```

### 5. Grant IAM roles for the GKE service account (one-time)

The pod uses Workload Identity with K8s SA mapped to GCP SA:
`${GKE_SERVICE_ACCOUNT}`

The `deploy_gke.sh` script grants all required roles automatically. For reference, these are the roles and why they're needed:

| Role | Purpose | Error if missing |
|---|---|---|
| `roles/aiplatform.user` | Vertex AI / Gemini model access | `Permission 'aiplatform.endpoints.predict' denied` |
| `roles/bigquery.dataEditor` | BigQuery table access for `BigQueryAgentAnalyticsPlugin` | `Permission bigquery.tables.get denied` |
| `roles/bigquery.jobUser` | BigQuery job creation for analytics plugin views | `User does not have bigquery.jobs.create permission` |
| `roles/cloudtrace.agent` | Cloud Trace export (`--otel_to_cloud`); includes `telemetry.traces.write` | `Permission 'telemetry.traces.write' denied` |
| `roles/logging.logWriter` | Cloud Logging export (`--otel_to_cloud`) | `Permission 'logging.logEntries.create' denied` |

Manual commands (if not using the script):

```bash
gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/aiplatform.user"

gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/cloudtrace.agent"

gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/logging.logWriter"
```

Verify assigned roles:

```bash
gcloud projects get-iam-policy ${GOOGLE_CLOUD_PROJECT} \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --format="table(bindings.role)"
```

### 6. Verify deployment

```bash
kubectl get deployments -n ${GKE_NAMESPACE}
kubectl get svc -n ${GKE_NAMESPACE}
kubectl get virtualservices -n ${GKE_NAMESPACE}
kubectl get pods -n ${GKE_NAMESPACE}

# Check both containers are ready (READY should show 2/2)
kubectl get pods -n ${GKE_NAMESPACE} -l app=bartek-adk-agent

# Logs for each container
kubectl logs -f deployment/bartek-adk-agent -n ${GKE_NAMESPACE} -c adk-web
kubectl logs -f deployment/bartek-adk-agent -n ${GKE_NAMESPACE} -c a2a
```

### 7. Port-forward to test locally

```bash
# ADK Web UI
kubectl port-forward svc/bartek-adk-agent 8000:8000 -n ${GKE_NAMESPACE}

# A2A Server
kubectl port-forward svc/bartek-adk-agent 8001:8001 -n ${GKE_NAMESPACE}
```

Then open http://localhost:8000 in your browser (ADK Web UI)
or test A2A at http://localhost:8001/.well-known/agent-card.json.

External URLs (via Istio VirtualService):

```
ADK Web UI:  https://bartek-adk-agent-${GKE_NAMESPACE}.${GKE_CLUSTER_SUBDOMAIN_INFIX}.${GKE_CLUSTER_REGION}.dev.${GKE_HTTP_URL_DOMAIN}
A2A Server:  https://bartek-adk-agent-a2a-${GKE_NAMESPACE}.${GKE_CLUSTER_SUBDOMAIN_INFIX}.${GKE_CLUSTER_REGION}.dev.${GKE_HTTP_URL_DOMAIN}
```

#### Testing A2A via curl

Fetch the Agent Card:

```bash
curl -s https://<A2A_EXTERNAL_URL>/.well-known/agent-card.json | python3 -m json.tool
```

Send a message (JSON-RPC `message/send`):

```bash
curl -s -X POST https://<A2A_EXTERNAL_URL> \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "msg-001",
        "role": "user",
        "parts": [
          {
            "kind": "text",
            "text": "Your prompt here"
          }
        ]
      }
    }
  }' | python3 -m json.tool
```

To extract only the relevant parts of the response (status, token usage, tools called, and
final text) — filtering out noise like `adk_thought_signature` and truncating large data
fields — pipe through `jq`:

```bash
A2A_URL="https://bartek-adk-agent-a2a-${GKE_NAMESPACE}.${GKE_CLUSTER_SUBDOMAIN_INFIX}.${GKE_CLUSTER_REGION}.dev.${GKE_HTTP_URL_DOMAIN}"

curl -s -X POST "${A2A_URL}" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "msg-001",
        "role": "user",
        "parts": [{"kind": "text", "text": "upgrade the Apache Beam and related dependencies in https://github.com/bmwieczorek/my-apache-beam-dataflow/blob/master/pom.xml"}]
      }
    }
  }' | jq '{
    status:      .result.status.state,
    timestamp:   .result.status.timestamp,
    token_usage: (.result.metadata.adk_usage_metadata | {
      prompt_tokens:   .promptTokenCount,
      cached_tokens:   .cachedContentTokenCount,
      response_tokens: .candidatesTokenCount,
      total_tokens:    .totalTokenCount
    }),
    tools_called: [
      .result.history[]
      | select(.parts[0].metadata.adk_type == "function_call")
      | {
          tool: .parts[0].data.name,
          args: (.parts[0].data.args | tostring | .[0:100])
        }
    ],
    response: .result.artifacts[0].parts[0].text
  }'
```

Expected output (XML comment lines removed from diff):

```json
{
  "status": "completed",
  "timestamp": "2026-04-21T18:40:44.137025+00:00",
  "token_usage": {
    "prompt_tokens": 44656,
    "cached_tokens": 32266,
    "response_tokens": 676,
    "total_tokens": 45538
  },
  "tools_called": [
    { "tool": "fetch_pom_xml",                         "args": "{\"url\":\"https://raw.githubusercontent.com/bmwieczorek/my-apache-beam-data" },
    { "tool": "get_bom_managed_versions",               "args": "{\"beam_version\":\"2.72.0\"}" },
    { "tool": "get_latest_maven_version_from_metadata", "args": "{\"group_id\":\"org.slf4j\",\"artifact_id\":\"slf4j-api\"}" },
    { "tool": "get_latest_maven_version_from_metadata", "args": "{\"group_id\":\"org.apache.avro\",\"artifact_id\":\"avro\"}" },
    { "tool": "get_latest_maven_version_from_metadata", "args": "{\"group_id\":\"org.apache.parquet\",\"artifact_id\":\"parquet-common\"}" },
    { "tool": "upgrade_pom_xml",                       "args": "{\"upgrades\":[{\"property\":\"slf4j.version\",\"new_version\":\"2.0.17\"" },
    { "tool": "generate_diff",                         "args": "{\"original_pom_xml\":\"<project xmlns=\\\"http://maven.apache.org/POM/4.0" }
  ],
  "response": "I have successfully upgraded the dependencies in the `pom.xml` file. Here is a summary of the changes:\n\n| Dependency | Old Version | New Version | Source |\n|---|---|---|---|\n| slf4j.version | 2.0.16 | 2.0.17 | Maven Central |\n| avro.version | 1.11.4 | 1.12.1 | Maven Central |\n| parquet.version | 1.15.2 | 1.17.0 | Maven Central |\n\nThe `beam.version` is already at the latest version of `2.72.0`, so no upgrade was needed.\n\nHere is the diff of the changes applied to the `pom.xml`:\n```diff\n--- pom.xml (original)\n+++ pom.xml (upgraded)\n-        <slf4j.version>2.0.16</slf4j.version>\n+        <slf4j.version>2.0.17</slf4j.version>\n-        <avro.version>1.11.4</avro.version>\n-        <parquet.version>1.15.2</parquet.version>\n+        <avro.version>1.12.1</avro.version>\n+        <parquet.version>1.17.0</parquet.version>\n```"
}
```

For streaming responses, use `message/sendStream` with unbuffered output:

```bash
curl -s -N -X POST https://<A2A_EXTERNAL_URL> \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/sendStream",
    "params": {
      "message": {
        "messageId": "msg-002",
        "role": "user",
        "parts": [{"kind": "text", "text": "Your prompt here"}]
      }
    }
  }'
```

> **Note:** Each `messageId` must be a unique string (e.g. a UUID). The `-N` flag
> disables curl output buffering so SSE events appear in real time.

### 8. Update deployment (after code changes)

```bash
# Auto-bumps image tag (e.g. 0.0.7 → 0.0.8), rebuilds, pushes, and redeploys
./deploy_gke.sh

# Or with an explicit tag
./deploy_gke.sh 1.0.0
```

## BigQuery Agent Analytics

The `BigQueryAgentAnalyticsPlugin` exports agent usage and token metrics to BigQuery.
Data is written to `${GOOGLE_CLOUD_PROJECT}.bartek_adk_agent_analytics.agent_events`.

### Token types

| Token type | Field | Description | Pricing |
|---|---|---|---|
| **Prompt (input)** | `prompt_token_count` | Total input tokens sent to the model. Includes system instructions, conversation history, tool results, and cached content. | Full input price |
| **Cached content** | `cached_content_token_count` | Portion of prompt tokens served from Vertex AI Context Cache. These are pre-cached contexts (e.g., large documents) that don't need re-processing. | **~75% cheaper** than regular input tokens |
| **Candidates (output)** | `candidates_token_count` | Tokens generated by the model in its response. | Output price (higher than input) |
| **Thoughts (thinking)** | `thoughts_token_count` | Tokens used for the model's internal reasoning (Gemini 2.5 "thinking" feature). Not visible in the response but counted toward usage. | Same as output price |
| **Tool use prompt** | `tool_use_prompt_token_count` | Tokens from tool execution results fed back to the model as input. | Same as input price |
| **Total** | `total_token_count` | Sum of `prompt_token_count` + `candidates_token_count` + `tool_use_prompt_token_count` + `thoughts_token_count`. | — |

> **Note:** `cached_content_token_count` is a **subset** of `prompt_token_count`, not additive.
> Effective billable input = (`prompt_token_count` - `cached_content_token_count`) × full price + `cached_content_token_count` × cached price.

### Which event types contain token data?

Out of all event types (`USER_MESSAGE_RECEIVED`, `AGENT_STARTING`, `INVOCATION_STARTING`,
`LLM_REQUEST`, `LLM_RESPONSE`, `TOOL_CALL`, `TOOL_RESPONSE`, `AGENT_RESPONSE`,
`INVOCATION_COMPLETE`), **only `LLM_RESPONSE`** has token-related attributes.

All token data lives under `attributes.usage_metadata` and includes the following keys:

| Attribute path | Description |
|---|---|
| `usage_metadata.prompt_token_count` | Total input tokens |
| `usage_metadata.cached_content_token_count` | Cached input tokens |
| `usage_metadata.candidates_token_count` | Output tokens |
| `usage_metadata.thoughts_token_count` | Thinking/reasoning tokens |
| `usage_metadata.tool_use_prompt_token_count` | Tool-use input tokens |
| `usage_metadata.total_token_count` | Sum of all token counts |
| `usage_metadata.cache_tokens_details` | Per-modality breakdown of cached tokens |
| `usage_metadata.candidates_tokens_details` | Per-modality breakdown of output tokens |
| `usage_metadata.prompt_tokens_details` | Per-modality breakdown of input tokens |
| `usage_metadata.tool_use_prompt_tokens_details` | Per-modality breakdown of tool-use tokens |

> **Note:** No other event type stores token counts in its `attributes`. This is why the query
> below filters on `event_type = "LLM_RESPONSE"`.

### Which event types mention tools?

Five event types reference tools in their `content` or `attributes`:

| Event type | Count | Where tools are mentioned |
|---|---|---|
| **`LLM_REQUEST`** | 37 | `attributes.tools` — list of available tool names (e.g. `execute_sql`, `forecast`); `content.system_prompt` — agent instructions mentioning tools |
| **`LLM_RESPONSE`** | 37 | `attributes.usage_metadata.tool_use_prompt_token_count` — tokens from tool results fed back to the model; `attributes.usage_metadata.tool_use_prompt_tokens_details` — per-modality breakdown |
| **`TOOL_STARTING`** | 24 | `content.tool` — name of the tool being invoked; `content.tool_origin` — origin (`LOCAL`) |
| **`TOOL_COMPLETED`** | 24 | `content.tool` — name of the tool that completed; `content.tool_origin` — origin; `content.result` — the tool's return value |
| **`AGENT_STARTING`** | 13 | `content` — system prompt text referencing tools (e.g. *"You are a helpful assistant with access to BigQuery tools."*) |

> **Note:** `TOOL_STARTING` and `TOOL_COMPLETED` are the primary event types for tracking
> individual tool invocations. `LLM_REQUEST` carries the full list of tools available to the
> model, while `LLM_RESPONSE` tracks how many tokens tool results consumed.

### Query: token usage per LLM response

```sql
SELECT
    timestamp,
    JSON_VALUE(content, '$.response') AS response,

    -- Summarized token counts (from content.usage, written by the plugin)
    CAST(JSON_VALUE(content, '$.usage.prompt') AS INT64) AS input_tokens,
    CAST(JSON_VALUE(content, '$.usage.completion') AS INT64) AS output_tokens,
    CAST(JSON_VALUE(content, '$.usage.total') AS INT64) AS total_tokens,
    -- Raw Gemini API metadata (from attributes.usage_metadata)
    CAST(JSON_VALUE(attributes, '$.usage_metadata.prompt_token_count') AS INT64) AS raw_prompt_tokens,
    CAST(JSON_VALUE(attributes, '$.usage_metadata.cached_content_token_count') AS INT64) AS cached_tokens,
    CAST(JSON_VALUE(attributes, '$.usage_metadata.candidates_token_count') AS INT64) AS raw_output_tokens,
    CAST(JSON_VALUE(attributes, '$.usage_metadata.thoughts_token_count') AS INT64) AS thinking_tokens,
    CAST(JSON_VALUE(attributes, '$.usage_metadata.tool_use_prompt_token_count') AS INT64) AS tool_use_tokens,
    CAST(JSON_VALUE(attributes, '$.usage_metadata.total_token_count') AS INT64) AS raw_total_tokens,
    -- Latency
    CAST(JSON_VALUE(latency_ms, '$.total_ms') AS INT64) AS total_ms,
    CAST(JSON_VALUE(latency_ms, '$.time_to_first_token_ms') AS INT64) AS ttft_ms,

    -- other
    agent,
    status,
    JSON_VALUE(attributes, '$.model_version') AS model_version

FROM `${GOOGLE_CLOUD_PROJECT}.bartek_adk_agent_analytics.agent_events`
WHERE TIMESTAMP_TRUNC(timestamp, DAY) = TIMESTAMP(CURRENT_DATE()-2)
  AND event_type = "LLM_RESPONSE"
ORDER BY timestamp DESC
    LIMIT 1000
```

### Cached tokens and billing

The plugin does **not** explicitly extract `cached_content_token_count` — it only extracts
`prompt`, `completion` (candidates), and `total` into `content.usage`. However, the **raw**
`usage_metadata` object from Gemini is stored as-is in `attributes.usage_metadata`, which
**does** include `cached_content_token_count` if context caching was used.

**`cached_content_token_count`** — The number of tokens from
[Vertex AI Context Caching](https://cloud.google.com/vertex-ai/generative-ai/docs/context-cache/context-cache-overview).
This is a feature where you pre-cache a large context (e.g., a long document, system instructions)
with the Gemini API so it doesn't need to be re-processed on every request.

**How it affects cost:**

| Field | Meaning | Billing |
|---|---|---|
| `prompt_token_count` | Total input tokens, **including** cached tokens | — |
| `cached_content_token_count` | Portion of prompt tokens served from cache | **~75% cheaper** than regular input |
| `prompt_token_count - cached_content_token_count` | Non-cached input tokens | Full input price |

**Billable input cost** = (`prompt_token_count` − `cached_content_token_count`) × full price + `cached_content_token_count` × discounted price

## Cloud Trace Observability

The ADK web server supports exporting OpenTelemetry traces to **Google Cloud Trace**.
This gives you distributed tracing of agent execution — spans for each agent invocation,
Gemini model calls (with token counts), tool calls, and plugin activity — all visible in
the GCP Trace Explorer.

### Prerequisites (one-time)

1. **Enable Cloud Trace API** on the target project:

   ```bash
   gcloud services enable cloudtrace.googleapis.com --project ${GOOGLE_CLOUD_PROJECT}
   gcloud services enable logging.googleapis.com --project ${GOOGLE_CLOUD_PROJECT}
   gcloud services enable telemetry.googleapis.com --project ${GOOGLE_CLOUD_PROJECT}
   ```

2. **Grant `roles/cloudtrace.agent`** to the identity that writes traces:

   - **Local (ADC):** your user account (already granted via `roles/owner` or `roles/editor`).
   - **GKE (Workload Identity):** already covered in [step 5 above](#5-grant-iam-roles-for-the-gke-service-account-one-time).

3. **Install the GenAI instrumentation package** (for Gemini call spans with token counts):

   ```bash
   pip install "opentelemetry-instrumentation-google-genai>=0.7b0,<1"
   ```

   > **⚠️ Version pinning is critical.** Installing without a pin (`pip install opentelemetry-instrumentation-google-genai`)
   > can pull in a newer `opentelemetry-api` (e.g. 1.40.0) that conflicts with `google-adk`'s constraint (`<1.39.0`)
   > and `opentelemetry-sdk`'s exact pin (`==1.38.0`). If this happens, fix with:
   >
   > ```bash
   > pip install "opentelemetry-api==1.38.0" "opentelemetry-semantic-conventions==0.59b0" "opentelemetry-instrumentation==0.59b0"
   > pip install "opentelemetry-instrumentation-google-genai>=0.7b0,<1"
   > pip check  # should print "No broken requirements found."
   > ```

### Running locally

Use the built-in ADK CLI flags — **do NOT configure a `TracerProvider` manually in `agent.py`**.
The ADK web server sets its own `TracerProvider` at startup, and OpenTelemetry forbids overriding it
(`"Overriding of current TracerProvider is not allowed"`).

There are two flags:

| Flag | What it does |
|------|-------------|
| `--trace_to_cloud` | Adds a `CloudTraceSpanExporter` — reads project from `GOOGLE_CLOUD_PROJECT` env var |
| `--otel_to_cloud` | Cloud Trace + Cloud Logging + auto-instruments GenAI SDK (Gemini call spans) — reads project from `google.auth.default()` |

**Recommended:** use `--otel_to_cloud` for full observability:

```bash
adk web --otel_to_cloud .
```

#### ADC quota project gotcha

`--otel_to_cloud` resolves the project via `google.auth.default()`, which uses the
**`quota_project_id`** stored in `~/.config/gcloud/application_default_credentials.json`.
This is set to whatever project was active when you ran `gcloud auth application-default login`.

If your ADC `quota_project_id` points to a different project (e.g. `other-project-id`
instead of `${GOOGLE_CLOUD_PROJECT}`), Cloud Trace API calls will be routed to the wrong project
and fail with a permission error.

**Fix:** re-run ADC login with the correct project:

```bash
gcloud auth application-default login --project ${GOOGLE_CLOUD_PROJECT}
```

Or override with an environment variable for a single run:

```bash
GOOGLE_CLOUD_QUOTA_PROJECT=${GOOGLE_CLOUD_PROJECT} adk web --otel_to_cloud .
```

Verify what your ADC currently targets:

```bash
python -c "import json; d=json.load(open('$HOME/.config/gcloud/application_default_credentials.json')); print('quota_project_id:', d.get('quota_project_id', '<not set>'))"
```

`--trace_to_cloud` does **not** have this problem — it reads `GOOGLE_CLOUD_PROJECT` directly.

### Running in Docker / GKE

Add the flag to the Dockerfile entrypoint:

```dockerfile
ENTRYPOINT ["adk", "web", "--host", "0.0.0.0", "--otel_to_cloud"]
```

The `opentelemetry-instrumentation-google-genai` package must also be in `requirements-docker.in`:

```
opentelemetry-instrumentation-google-genai>=0.7b0,<1
```

On GKE with Workload Identity, `google.auth.default()` returns the pod's service account
and project, so the ADC quota project issue does not apply.

### Viewing traces

1. Open **Google Cloud Console → Trace Explorer**:
   ```
   https://console.cloud.google.com/traces/list?project=${GOOGLE_CLOUD_PROJECT}
   ```

2. Filter by span name, e.g.:
   - `invoke_agent my_bq_agent` — top-level agent invocation
   - `call_llm` — ADK-level LLM call span
   - `generate_content` / `generate_content gemini-2.5-flash` — GenAI SDK model call spans (with `gen_ai.usage.input_tokens` / `gen_ai.usage.output_tokens` attributes)

3. Traces appear after a short delay (~10–30s) due to `BatchSpanProcessor` flushing.

### Querying trace spans in BigQuery

Cloud Trace data is also accessible via the `_Trace._AllSpans` view in BigQuery.
This allows SQL-based analysis of spans, token usage, and latency.

**Token usage per Gemini call (from Cloud Trace spans):**

```sql
-- Span hierarchy (parent → child):
--   invoke_agent my_bq_agent  →  call_llm  →  generate_content gemini-2.5-flash
--
-- Token attributes (gen_ai.usage.*) are only on generate_content spans.
-- call_llm spans have NULL tokens — don't COALESCE to 0, it hides the difference.
--
-- ⚠️  Always keep a time filter on _AllSpans — it is an ever-growing view and
--     a full scan gets slower and more expensive every day.

SELECT
    start_time,
    name,
    SAFE_CAST(JSON_VALUE(attributes, '$."gen_ai.usage.input_tokens"')  AS INT64) AS input_tokens,
    SAFE_CAST(JSON_VALUE(attributes, '$."gen_ai.usage.output_tokens"') AS INT64) AS output_tokens,
    trace_id,
    span_id,
    parent_span_id,
    end_time,
    TIMESTAMP_DIFF(end_time, start_time, MILLISECOND) AS duration_ms,
    attributes
FROM
    `${GOOGLE_CLOUD_PROJECT}.global._Trace._AllSpans`
WHERE
    start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
    AND trace_id IN (
        SELECT trace_id
        FROM `${GOOGLE_CLOUD_PROJECT}.global._Trace._AllSpans`
        WHERE name = 'invoke_agent my_bq_agent'
          AND start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
    )
    AND (name = 'call_llm' OR name LIKE 'generate_content%')
ORDER BY
    start_time ASC
LIMIT 1000
```

> **Note:** This is different from the `BigQueryAgentAnalyticsPlugin` data in
> `bartek_adk_agent_analytics.agent_events`. Cloud Trace spans give you distributed tracing
> with parent-child relationships and timing. The BQ plugin gives you structured agent events
> with detailed token breakdowns. They complement each other.

## Apache Beam Maven Dependency Upgrade Agent (`my_upgrade_agent`)

An ADK agent that upgrades Apache Beam and related dependencies in a `pom.xml` following the
BOM (Bill of Materials) chain: **Beam → libraries-bom → google-cloud-bom → individual libraries**.

Based on the approach documented in the
[my-upgrade-apache-beam-maven-dependencies](https://github.com/bmwieczorek/my-apache-beam-dataflow/blob/master/.github/skills/my-upgrade-apache-beam-maven-dependencies/SKILL.md) skill.

### How it works

1. Provide the agent with a **raw HTTP link** to a `pom.xml` (e.g. a GitHub raw URL)
2. The agent fetches and parses the `pom.xml`, extracting `<properties>` version values
3. Finds the **latest Beam release** from Maven Central
4. Resolves the **BOM chain**: Beam → `libraries-bom` (from `BeamModulePlugin.groovy`) → `google-cloud-bom` (from `libraries-bom` POM) → BigQuery & Storage versions (from `google-cloud-bom` POM)
5. Checks **independently versioned** dependencies (hadoop, slf4j, commons-codec, parquet, junit) via `maven-metadata.xml`
6. Applies property upgrades and returns a **unified diff** and summary table

### BOM-chain dependencies (versions from BOM)

| Dependency | Source |
|---|---|
| `beam.version` | Maven Central `maven-metadata.xml` |
| `libraries-bom` | Beam's `BeamModulePlugin.groovy` |
| `google-cloud-bom` | `libraries-bom` POM |
| `google-cloud-bigquery.version` | `google-cloud-bom` POM |
| `google-cloud-storage.version` | `google-cloud-bom` POM |

### Independently versioned dependencies (versions from Maven Central)

| Dependency | Maven metadata artifact |
|---|---|
| `hadoop.version` | `org.apache.hadoop:hadoop-common` |
| `slf4j.version` | `org.slf4j:slf4j-api` (excludes alpha/beta) |
| `commons-codec.version` | `commons-codec:commons-codec` |
| `parquet.version` | `org.apache.parquet:parquet-avro` |
| `junit.version` | `junit:junit` |

### Tools

| Tool | Description |
|------|-------------|
| `fetch_pom_xml` | Downloads a `pom.xml` from an HTTP URL |
| `parse_pom_dependencies` | Parses dependencies, plugins, properties, and resolves `${...}` placeholders |
| `get_latest_beam_version` | Gets latest Beam release from Maven Central `maven-metadata.xml` |
| `get_libraries_bom_version_from_beam` | Resolves `libraries-bom` version from Beam's `BeamModulePlugin.groovy` |
| `get_google_cloud_bom_version_from_libraries_bom` | Resolves `google-cloud-bom` version from `libraries-bom` POM |
| `get_bom_managed_versions` | Gets BigQuery and Storage versions from `google-cloud-bom` POM |
| `get_latest_maven_version_from_metadata` | Gets latest stable version from Maven Central for independently versioned deps |
| `upgrade_pom_xml` | Applies version upgrades (property-based) to the raw XML text |
| `generate_diff` | Produces a unified diff between original and upgraded `pom.xml` |

### Running locally

```bash
adk web .
# Then select "my_upgrade_agent" in the ADK web UI
```

Example prompt:

> Please upgrade the dependencies in this pom.xml: https://raw.githubusercontent.com/bmwieczorek/my-apache-beam-dataflow/master/pom.xml

### Talking to the agent via REST API (ADK web)

The `adk web` server exposes a REST API that can be used directly with `curl`.
The flow is: **create a session → send a message via `/run_sse`**.

#### 1. Local (`adk web .`)

```bash
BASE=http://localhost:8000
APP=my_upgrade_agent
USER=test_user

# Create a session
SESSION_ID=$(curl -s -X POST "$BASE/apps/$APP/users/$USER/sessions" \
  -H "Content-Type: application/json" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Session: $SESSION_ID"

# Send a message (SSE streaming)
curl -N -X POST "$BASE/run_sse" \
  -H "Content-Type: application/json" \
  -d "{
    \"app_name\": \"$APP\",
    \"user_id\": \"$USER\",
    \"session_id\": \"$SESSION_ID\",
    \"new_message\": {
      \"role\": \"user\",
      \"parts\": [{\"text\": \"Please upgrade the dependencies in this pom.xml: https://raw.githubusercontent.com/bmwieczorek/my-apache-beam-dataflow/master/pom.xml\"}]
    },
    \"streaming\": true
  }"
```

#### 2. Docker / Podman (default ADK mode)

Same curl commands, but the base URL matches the published port:

```bash
BASE=http://localhost:8000   # -p 8000:8000 in docker run
```

#### 3. GKE

```bash
BASE=https://bartek-adk-agent-${GKE_NAMESPACE}.apps.dev-03.${GKE_CLUSTER_REGION}.dev.${GKE_HTTP_URL_DOMAIN}
```

Then use the same session-creation + `/run_sse` flow as above.

#### Key ADK web endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/list-apps` | List all agent apps |
| `GET` | `/health` | Health check |
| `POST` | `/apps/{app}/users/{user}/sessions` | Create a new session |
| `GET` | `/apps/{app}/users/{user}/sessions` | List sessions |
| `GET` | `/apps/{app}/users/{user}/sessions/{id}` | Get session details + events |
| `POST` | `/run` | Run agent (returns all events at once) |
| `POST` | `/run_sse` | Run agent (Server-Sent Events stream) |
| `WS` | `/run_live` | Live/streaming via WebSocket |

### Talking to the agent via A2A protocol

`my_upgrade_agent` already declares an `A2AConfig` in its `App` definition, so
`adk web` automatically serves A2A endpoints when the agent is loaded.

When running via the standalone `a2a_server.py` (or Docker with `SERVE_MODE=a2a`),
the A2A JSONRPC endpoints are served at the root.

#### Discover the Agent Card

```bash
# Via adk web (multi-agent — card per app):
curl -s http://localhost:8000/.well-known/agent-card.json | python3 -m json.tool

# Via standalone a2a_server.py:
curl -s http://localhost:8000/.well-known/agent-card.json | python3 -m json.tool
```

#### Send a message via A2A JSONRPC

```bash
curl -X POST http://localhost:8000/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "upgrade-001",
        "role": "user",
        "parts": [{"kind": "text", "text": "Please upgrade the dependencies in this pom.xml: https://raw.githubusercontent.com/bmwieczorek/my-apache-beam-dataflow/master/pom.xml"}]
      }
    },
    "id": 1
  }'
```

### A2A client tools

#### 1. A2A Inspector (recommended for visual testing)

A web-based tool from the [A2A project](https://github.com/a2aproject/a2a-inspector)
(397+ ⭐) for inspecting, debugging, and validating A2A-compliant agents.
Think of it as **Postman for A2A agents**.

**What it does:**

| Feature | Description |
|---------|-------------|
| **Agent Card viewer** | Fetches and displays `/.well-known/agent-card.json` |
| **Spec compliance checks** | Validates the agent card against the A2A specification |
| **Live chat** | Chat interface to send/receive messages with the agent |
| **Debug console** | Slide-out panel showing raw JSON-RPC 2.0 request/response traffic |

**Prerequisites:**

| Option | Requirements |
|--------|-------------|
| Run locally | Python 3.10+, [uv](https://github.com/astral-sh/uv), Node.js + npm |
| Run with Docker | Docker only |

**Option A — Run via Docker (⚠️ does NOT work with host-based agents):**

```bash
git clone https://github.com/a2aproject/a2a-inspector.git
cd a2a-inspector
docker build -t a2a-inspector .
docker run -d -p 8080:8080 a2a-inspector
```

Open **http://127.0.0.1:8080**, enter `http://host.docker.internal:8000` as
the agent URL. The inspector **fetches the Agent Card successfully**, but when
you try to chat you get:

```
Error: Failed to send message: HTTP Error 503: Network communication error: All connection attempts failed
```

**Why it fails:** The agent card contains `"url": "http://0.0.0.0:8000"` — this
is the address the A2A server (`to_a2a()`) embeds in its own agent card. While
the inspector can reach the agent for the initial card fetch (via the URL you
typed — `host.docker.internal:8000`), when it sends chat messages it uses the
`url` field **from the agent card itself** (`0.0.0.0:8000`), which is
unreachable from inside the Docker container.

**Workaround:** Restart the agent with `A2A_HOST=host.docker.internal` so the
agent card advertises a Docker-reachable URL:

```bash
A2A_HOST=host.docker.internal A2A_AGENT_MODULE=my_multi_agent python a2a_server.py
```

**Cleanup** (stop and remove the Docker inspector container):

```bash
docker ps -q --filter ancestor=a2a-inspector | xargs docker stop | xargs docker rm
```

---

**Option B — Run locally (✅ recommended):**

Prerequisites: Python 3.10+, [uv](https://github.com/astral-sh/uv), Node.js + npm.

**Step 1 — Install uv (if not already installed):**

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**Step 2 — Clone and install:**

```bash
cd ~/dev
git clone https://github.com/a2aproject/a2a-inspector.git
cd a2a-inspector
uv sync                                    # install Python deps
cd frontend && npm install && cd ..        # install frontend deps
```

**Step 3 — Start the inspector:**

```bash
bash scripts/run.sh
```

This starts both the backend (FastAPI) and frontend (TypeScript build watcher).

**Step 4 — Start the agent** (in a separate terminal):

```bash
cd ~/dev/my-adk-python-agent
A2A_AGENT_MODULE=my_multi_agent python a2a_server.py
```

**Step 5 — Connect:**

Open **http://127.0.0.1:5001** in your browser. Enter the agent card URL:

```
http://localhost:8000
```

Click **Connect**. The inspector fetches the Agent Card and validates it:

```
Agent card is valid.

{
  "capabilities": {},
  "defaultInputModes": ["text/plain"],
  "defaultOutputModes": ["text/plain"],
  "description": "Bartek Currency Converter Agent Latest",
  "name": "bartek_currency_converter_agent_latest",
  "preferredTransport": "JSONRPC",
  "protocolVersion": "0.3.0",
  "skills": [
    {
      "description": "Bartek Currency Converter Agent Latest ...",
      "id": "bartek_currency_converter_agent_latest",
      "name": "model",
      "tags": ["llm"]
    },
    {
      "description": "Call self as a function.",
      "id": "bartek_currency_converter_agent_latest-get_current_time",
      "name": "get_current_time",
      "tags": ["llm", "tools"]
    },
    {
      "description": "Call self as a function.",
      "id": "bartek_currency_converter_agent_latest-get_currency_rate",
      "name": "get_currency_rate",
      "tags": ["llm", "tools"]
    }
  ],
  "supportsAuthenticatedExtendedCard": false,
  "url": "http://0.0.0.0:8000",
  "version": "0.0.1"
}
```

**Step 6 — Chat with the agent:**

Type `1 EUR to PLN` in the Live Chat and send. The inspector shows:

```
task
2026-04-19 18:13:58 - 1 EUR is 4.227448472 PLN ✅
```

**Step 7 — Debug:**

Open the **Debug Console** (slide-out panel) to see the raw JSON-RPC 2.0
`message/send` request and response exchanged with the agent.

**Step 8 — Stop:**

Press `Ctrl+C` in the terminal running `scripts/run.sh`.

#### 2. Python client with `a2a-sdk`

Install the SDK:

```bash
pip install "a2a-sdk[http-server]"
```

Minimal client script (`a2a_client.py`):

```python
"""Minimal A2A client that sends a message and prints the response."""

import asyncio
from uuid import uuid4

import httpx
from a2a.client import A2ACardResolver
from a2a.client.client import ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.types import Message, Part, Role, SendMessageRequest


async def main():
    base_url = "http://localhost:8000"

    async with httpx.AsyncClient() as httpx_client:
        # 1. Fetch the Agent Card
        resolver = A2ACardResolver(httpx_client=httpx_client, base_url=base_url)
        card = await resolver.get_agent_card()
        print(f"Agent: {card.name}")

        # 2. Create a non-streaming client
        client = ClientFactory(config=ClientConfig(streaming=False)).create(card)

        # 3. Send a message
        request = SendMessageRequest(
            message=Message(
                role=Role.ROLE_USER,
                message_id=uuid4().hex,
                parts=[Part(text="1 usd to pln")],
            )
        )
        response = client.send_message(request)
        async for task, _ in response:
            print(f"Response: {task}")

        await client.close()


if __name__ == "__main__":
    asyncio.run(main())
```

Run:

```bash
python a2a_client.py
```

#### 3. A2A HelloWorld sample (quick protocol validation)

The official A2A samples repo includes a ready-to-run test client:

```bash
git clone https://github.com/a2aproject/a2a-samples.git
cd a2a-samples/samples/python/agents/helloworld

# Terminal 1: start the sample agent (port 9999)
uv run .

# Terminal 2: run the test client
uv run test_client.py
```

This validates your environment's A2A compatibility end-to-end.

#### Tool comparison

| Tool | Best for | Install effort |
|------|----------|---------------|
| **curl** | Quick smoke tests, CI/CD | None — already available |
| **A2A Inspector** | Visual debugging, spec validation | `git clone` + `uv sync` or Docker |
| **Python `a2a-sdk`** | Programmatic integration, test scripts | `pip install a2a-sdk` |
| **A2A samples** | End-to-end protocol validation | `git clone` + `uv` |

