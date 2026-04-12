SELECT
    start_time,
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$."gen_ai.usage.input_tokens"') AS INT64), 0) as input_tokens,
    COALESCE(SAFE_CAST(JSON_VALUE(attributes, '$."gen_ai.usage.output_tokens"') AS INT64), 0) AS output_tokens
FROM
    -- replace project-id with real project
    `project-id.global._Trace._AllSpans`
WHERE
    JSON_VALUE(attributes, '$."gen_ai.operation.name"') = 'generate_content'
  AND JSON_VALUE(attributes, '$."gen_ai.request.model"') IS NOT NULL
  AND JSON_VALUE(attributes, '$."gen_ai.agent.name"') = 'my_upgrade_agent'
GROUP BY
    1, 2, 3;