SELECT
    timestamp,
    JSON_VALUE(content, '$.response') AS response,

    -- Summarized token counts (from content.usage, written by the bq_agent_analytics plugin)
    COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.prompt') AS INT64), 0) AS input_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.completion') AS INT64), 0) AS output_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.total') AS INT64), 0) AS total_tokens,

    -- Raw Gemini API metadata (from attributes.usage_metadata)
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$.usage_metadata.prompt_token_count') AS INT64), 0) AS raw_prompt_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$.usage_metadata.cached_content_token_count') AS INT64), 0) AS cached_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$.usage_metadata.candidates_token_count') AS INT64), 0) AS raw_output_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$.usage_metadata.thoughts_token_count') AS INT64), 0) AS thinking_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$.usage_metadata.tool_use_prompt_token_count') AS INT64), 0) AS tool_use_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$.usage_metadata.total_token_count') AS INT64), 0) AS raw_total_tokens,

    -- Latency
    COALESCE(SAFE_CAST(JSON_VALUE(latency_ms, '$.total_ms') AS INT64), 0) AS total_ms,
    COALESCE(SAFE_CAST(JSON_VALUE(latency_ms, '$.time_to_first_token_ms') AS INT64), 0) AS ttft_ms,

    -- other
    agent,
    status,
    JSON_VALUE(attributes, '$.model_version') AS model_version,

    session_id,
    invocation_id,
    trace_id,
    span_id
FROM `bartek_adk_agent_analytics.agent_events`
WHERE TIMESTAMP_TRUNC(timestamp, DAY) = TIMESTAMP(CURRENT_DATE())
  AND event_type = "LLM_RESPONSE"
ORDER BY timestamp DESC
    LIMIT 100
