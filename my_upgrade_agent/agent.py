# my_upgrade_agent/agent.py
#
# ADK agent that upgrades Apache Beam and related Maven dependencies in a pom.xml.
# Follows the BOM-chain approach documented at:
#   https://github.com/bmwieczorek/my-apache-beam-dataflow/blob/master/.github/skills/my-upgrade-apache-beam-maven-dependencies/SKILL.md
#
# BOM chain: Beam → libraries-bom → google-cloud-bom → individual library versions
#
# Usage:
#   Provide the agent with a raw HTTP link to a pom.xml (e.g. a GitHub raw URL)
#   and it will:
#     1. Fetch the pom.xml and parse current versions
#     2. Find the latest Beam release
#     3. Resolve libraries-bom version from Beam's BeamModulePlugin.groovy
#     4. Resolve google-cloud-bom version from libraries-bom POM
#     5. Resolve BigQuery and Storage versions from google-cloud-bom POM
#     6. Check latest stable versions of independently versioned deps (hadoop, slf4j, etc.)
#     7. Apply upgrades and return a diff

import logging
import os
from google.adk.apps import App
from google.adk.plugins.bigquery_agent_analytics_plugin import BigQueryAgentAnalyticsPlugin, BigQueryLoggerConfig
from google.adk.agents import Agent
from google.adk.plugins import ReflectAndRetryToolPlugin

from .tools import (
    fetch_pom_xml,
    generate_diff,
    get_bom_managed_versions,
    get_google_cloud_bom_version_from_libraries_bom,
    get_latest_beam_version,
    get_latest_maven_version_from_metadata,
    get_libraries_bom_version_from_beam,
    parse_pom_dependencies,
    upgrade_pom_xml,
)

logger = logging.getLogger(__name__)

# --- Configuration ---
PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "your-gcp-project-id")
DATASET_ID = os.environ.get("BIG_QUERY_DATASET_ID", "your-big-query-dataset-id")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "US")
GCS_BUCKET = os.environ.get("GCS_BUCKET", "your-gcs-bucket") # Optional

if PROJECT_ID == "your-gcp-project-id":
    raise ValueError("Please set GOOGLE_CLOUD_PROJECT or update the code.")

# --- CRITICAL: Set environment variables BEFORE Gemini instantiation ---
os.environ['GOOGLE_CLOUD_PROJECT'] = PROJECT_ID
os.environ['GOOGLE_CLOUD_LOCATION'] = LOCATION
os.environ['GOOGLE_GENAI_USE_VERTEXAI'] = 'True'


# --- Initialize the BQ Agent Analytics Plugin ---
bq_config = BigQueryLoggerConfig(
    enabled=True,
    gcs_bucket_name=GCS_BUCKET, # Enable GCS offloading for multimodal content
    log_multi_modal_content=True,
    max_content_length=500 * 1024, # 500 KB limit for inline text
    batch_size=1, # Default is 1 for low latency, increase for high throughput
    shutdown_timeout=10.0
)

bq_agent_analytics_plugin = BigQueryAgentAnalyticsPlugin(
    project_id=PROJECT_ID,
    dataset_id=DATASET_ID,
    table_id="agent_events",
    config=bq_config,
    location=LOCATION
)


# ---------------------------------------------------------------------------
# Retry plugin — detects {"status": "error"} in tool responses as failures
# ---------------------------------------------------------------------------

class ToolErrorRetryPlugin(ReflectAndRetryToolPlugin):
    """Extends ReflectAndRetryToolPlugin to also detect soft errors.

    Our tools return {"status": "error", "message": "..."} on HTTP/parsing
    failures instead of raising exceptions. This override ensures the plugin
    treats those as retriable failures so the LLM can reflect and retry.
    """

    async def extract_error_from_result(self, *, tool, tool_args, tool_context, result):
        if isinstance(result, dict) and result.get("status") == "error":
            return result
        return None


# ---------------------------------------------------------------------------
# Error callbacks
# ---------------------------------------------------------------------------

def _on_model_error(ctx, request, error):
    logger.error(
        f"LLM call failed for agent={ctx.agent_name} invocation={ctx.invocation_id} "
        f"model={request.model}: {error}"
    )
    return None


# ---------------------------------------------------------------------------
# Retry plugin
# ---------------------------------------------------------------------------

# Retries tool failures up to 3 times, letting the LLM reflect on errors.
# Also catches soft errors ({"status": "error"}) from our HTTP-based tools.
retry_plugin = ToolErrorRetryPlugin(max_retries=3)

# The ADK framework calls canonical after_tool_callbacks with (tool, args, tool_context, tool_response)
# but the plugin expects (tool, tool_args, tool_context, result). Wrap to translate.

async def _after_tool_callback(tool, args, tool_context, tool_response):
    return await retry_plugin.after_tool_callback(
        tool=tool, tool_args=args, tool_context=tool_context, result=tool_response,
    )

async def _on_tool_error_callback(tool, args, tool_context, error):
    return await retry_plugin.on_tool_error_callback(
        tool=tool, tool_args=args, tool_context=tool_context, error=error,
    )


# ---------------------------------------------------------------------------
# Agent definition
# ---------------------------------------------------------------------------

# To list available Gemini models in the project (no gcloud command exists for publisher/foundation models):
# python -c "
# from google import genai; import os
# project = os.environ['GOOGLE_CLOUD_PROJECT']
# location = os.environ['GOOGLE_CLOUD_LOCATION']
# os.environ['GOOGLE_GENAI_USE_VERTEXAI']='True'
# client = genai.Client(vertexai=True, project=project, location=location)
# [print(m.name) for m in client.models.list() if 'gemini' in m.name.lower() and 'pro' in m.name.lower()]
# "
# Note: `gcloud ai models list` only lists custom/uploaded models, NOT publisher models like Gemini.
# As of 2026-04-10 available pro models: gemini-2.5-pro, gemini-3-pro-preview, gemini-3.1-pro-preview

root_agent = Agent(
    name="my_upgrade_agent",
    model="gemini-2.5-pro", # gemini 2.5 flash cannot parse xml with <!-- --> comments (pom.xml)
    description="Apache Beam Maven Dependency Upgrade Agent",
    instruction="""You are an Apache Beam Maven dependency upgrade assistant.
Your job is to upgrade Apache Beam and related dependencies in a pom.xml following
the BOM (Bill of Materials) chain: Beam → libraries-bom → google-cloud-bom → individual libraries.

Follow these steps EXACTLY:

### Step 1: Fetch and parse the pom.xml
Use `fetch_pom_xml` to download the pom.xml from the user-provided URL.
Then use `parse_pom_dependencies` to extract current version properties and dependencies.
Note the current values of these properties: beam.version, google-cloud-bigquery.version,
google-cloud-storage.version, hadoop.version, slf4j.version, commons-codec.version,
parquet.version, avro.version, junit.version, hamcrest.version, and any others.

### Step 2: Find the latest Beam release
Use `get_latest_beam_version` to get the latest Apache Beam version from Maven Central.
This returns both the full version (e.g. '2.72.0') and the minor version (e.g. '2.72').

### Step 3: Get libraries-bom version from Beam
Use `get_libraries_bom_version_from_beam` with the beam_minor version from Step 2.
This fetches the libraries-bom version from Beam's BeamModulePlugin.groovy.

### Step 4: Resolve google-cloud-bom version
Use `get_google_cloud_bom_version_from_libraries_bom` with the libraries-bom version from Step 3.
This follows the BOM chain: libraries-bom → google-cloud-bom.

### Step 5: Get BOM-managed library versions
Use `get_bom_managed_versions` with the google-cloud-bom version from Step 4.
This returns the BigQuery and Storage versions that are compatible with the Beam BOM chain.

**IMPORTANT:** Do NOT use maven-metadata.xml for BigQuery or Storage versions.
These MUST come from the google-cloud-bom to ensure BOM compatibility.

### Step 6: Check independently versioned dependencies
For dependencies NOT managed by the Beam BOM chain, use `get_latest_maven_version_from_metadata`
to find the latest stable version. These are:
- hadoop: group_id='org.apache.hadoop', artifact_id='hadoop-common'
- parquet: group_id='org.apache.parquet', artifact_id='parquet-avro'
- slf4j: group_id='org.slf4j', artifact_id='slf4j-api', exclude_patterns='alpha,beta'
- junit: group_id='junit', artifact_id='junit'
- commons-codec: group_id='commons-codec', artifact_id='commons-codec'

For slf4j, use exclude_patterns='alpha,beta' because <latest> returns alpha versions.
For major version bumps (e.g. parquet 1.15→1.17), keep the current version for safety
unless the user explicitly requests it.

### Step 7: Apply upgrades
Build the upgrade list and use `upgrade_pom_xml` to apply changes. Use property-based
upgrades (the 'property' field) for all version properties:
- beam.version
- google-cloud-bigquery.version
- google-cloud-storage.version
- hadoop.version
- slf4j.version
- commons-codec.version
- (and any other properties that have newer versions)

Only upgrade properties that actually exist in the pom.xml <properties> section.
Skip properties whose version hasn't changed.

### Step 8: Generate and present the diff
Use `generate_diff` to produce a unified diff between the original and upgraded pom.xml.

### Step 9: Present summary
Show a summary table with these columns:
| Dependency | Old Version | New Version | Source |

Where Source indicates where the new version came from:
- "Maven Central" for Beam and independently versioned deps
- "Beam BeamModulePlugin.groovy" for libraries-bom
- "libraries-bom POM" for google-cloud-bom
- "google-cloud-bom" for BigQuery and Storage

Include the diff output as well.

### Important notes
- This is specifically for Apache Beam BOM-chain upgrades, not a generic dependency upgrader.
- Always follow the BOM chain for Google Cloud libraries (BigQuery, Storage).
- For independently versioned dependencies, use maven-metadata.xml.
- Skip SNAPSHOT versions.
- If a version hasn't changed, don't include it in the upgrades.
""",
    tools=[
        fetch_pom_xml,
        parse_pom_dependencies,
        get_latest_beam_version,
        get_libraries_bom_version_from_beam,
        get_google_cloud_bom_version_from_libraries_bom,
        get_bom_managed_versions,
        get_latest_maven_version_from_metadata,
        upgrade_pom_xml,
        generate_diff,
    ],
    after_tool_callback=_after_tool_callback,
    on_tool_error_callback=_on_tool_error_callback,
    on_model_error_callback=_on_model_error,
)

# --- Create the App ---
app = App(
    name="my_upgrade_agent",
    root_agent=root_agent,
    plugins=[bq_agent_analytics_plugin],
)
