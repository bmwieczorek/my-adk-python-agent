# MacOS setup

## Prerequisites

```bash
brew install --cask visual-studio-code
brew install --cask podman-desktop
brew install podman
brew tap slp/krun
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
| `requirements-docker.in` → `requirements-docker.txt` | Lean deps for running in Docker/Podman (`adk web`) — only `google-adk` + `pendulum`             |
| `requirements.in` → `requirements.txt`               | Full deps for Vertex AI Agent Engine deployment (`deploy.py`, `delete.py`, `api.py`, `rest.py`) |

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

```bash
docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI=TRUE -t bartek-adk-agent . && docker image prune -f
#(docker rm -f bartek-adk-agent 2>/dev/null || true) && docker run --name bartek-adk-agent -p 8000:8000 -it \
#  -e GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT} \
#  -e GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION} \
#  -e BIG_QUERY_DATASET_ID=${BIG_QUERY_DATASET_ID} \
#  -e GCS_BUCKET=${GCS_BUCKET} \
#  -v "$HOME/.config/gcloud/application_default_credentials.json:/tmp/adc.json:ro" \
#  -e GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json \
#  bartek-adk-agent && docker container prune -f

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
export AGENT_IMAGE_URI=...                 # e.g. ${AGENT_IMAGE_REPO}:0.0.3
export GKE_SERVICE_ACCOUNT=...             # GCP SA email (e.g. name@project.iam.gserviceaccount.com); K8s SA name is derived as part before '@'
export GKE_HTTP_URL_DOMAIN=...             # e.g. example.com


./deploy_gke.sh
```

You can put these exports in `.bash_profile` and open a new terminal before running the script.

The script expects `GCS_BUCKET` directly.

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

Traffic flow between browser and pod:

```
Browser → Istio Gateway → VirtualService → Service (ClusterIP) → Pod
```

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

# Runtime values passed to the Deployment via kubectl set env
export GOOGLE_CLOUD_PROJECT=...
export GOOGLE_CLOUD_LOCATION=...
export BIG_QUERY_DATASET_ID=...
export GCS_BUCKET=...

kubectl set env deployment/bartek-adk-agent -n ${GKE_NAMESPACE} \
  GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT}" \
  GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION}" \
  BIG_QUERY_DATASET_ID="${BIG_QUERY_DATASET_ID}" \
  GCS_BUCKET="${GCS_BUCKET}"

kubectl rollout status deployment/bartek-adk-agent -n ${GKE_NAMESPACE}
```

### 5. Grant Vertex AI permissions (one-time, already done ✅)

The pod uses Workload Identity with K8s SA mapped to GCP SA:
`${GKE_SERVICE_ACCOUNT}`

This SA needs the `Vertex AI User` role on project `${GOOGLE_CLOUD_PROJECT}` to call the Gemini model:

```bash
gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/aiplatform.user"
```

### 6. Grant BigQuery permissions (one-time)

The `BigQueryAgentAnalyticsPlugin` (in `bartek_adk_agent/agent.py`) and `BigQueryToolset` (in `my_bq_agent/agent.py`)
both need BigQuery access. The same Workload Identity SA needs `BigQuery Data Editor` and `BigQuery Job User`
roles on project `${GOOGLE_CLOUD_PROJECT}`:

```bash
gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
  --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
  --role="roles/bigquery.jobUser"
```

### 7. Verify deployment

```bash
kubectl get deployments -n ${GKE_NAMESPACE}
kubectl get svc -n ${GKE_NAMESPACE}
kubectl get virtualservices -n ${GKE_NAMESPACE}
kubectl get pods -n ${GKE_NAMESPACE}
kubectl logs -f deployment/bartek-adk-agent -n ${GKE_NAMESPACE}
```

### 8. Port-forward to test locally

```bash
kubectl port-forward svc/bartek-adk-agent 8000:80 -n ${GKE_NAMESPACE}
```

Then open http://localhost:8000 in your browser.

External URL (via Istio VirtualService):

```
https://bartek-adk-agent-${GKE_NAMESPACE}.apps.dev-03.${GKE_CLUSTER_REGION}.dev.${GKE_HTTP_URL_DOMAIN}
```

### 9. Update deployment (after pushing a new image)

```bash
kubectl rollout restart deployment/bartek-adk-agent -n ${GKE_NAMESPACE}
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
   ```

2. **Grant `roles/cloudtrace.agent`** to the identity that writes traces:

   - **Local (ADC):** your user account (already granted via `roles/owner` or `roles/editor`).
   - **GKE (Workload Identity):** the GKE service account:

     ```bash
     gcloud projects add-iam-policy-binding ${GOOGLE_CLOUD_PROJECT} \
       --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
       --role="roles/cloudtrace.agent"
     ```

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

