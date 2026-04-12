SELECT
    MIN(timestamp) as start_ts,
    agent,

    SUM(COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.prompt') AS INT64), 0)) AS input_tokens,
    SUM(COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.completion') AS INT64), 0)) AS output_tokens,

    -- Cost without discount (Gemini 2.5 PRO: input $1.25/1M, output $10.00/1M) https://ai.google.dev/gemini-api/docs/pricing#gemini-2.5-pro (gemini 2.5 flash cannot parse comments in xml)
    ROUND(SUM(COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.prompt') AS INT64), 0)) * 1.25 / 1000000, 6) AS input_cost_usd,
    ROUND(SUM(COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.completion') AS INT64), 0)) * 10.00 / 1000000, 6) AS output_cost_usd,
    ROUND(
            SUM(COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.prompt') AS INT64), 0)) * 1.25 / 1000000
                + SUM(COALESCE(SAFE_CAST(JSON_VALUE(content, '$.usage.completion') AS INT64), 0)) * 10.00 / 1000000
        , 6) AS total_cost_usd,

    session_id,
    invocation_id,
    trace_id

FROM `bartek_adk_agent_analytics.agent_events`
WHERE TIMESTAMP_TRUNC(timestamp, DAY) = TIMESTAMP(CURRENT_DATE())
  AND event_type = "LLM_RESPONSE"
GROUP BY
    agent,
    session_id,
    invocation_id,
    trace_id
ORDER BY start_ts DESC
    LIMIT 100
