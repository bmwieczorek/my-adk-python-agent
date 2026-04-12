SELECT
    start_time as _start_time,
    trace_id as _trace_id,
    SAFE_CAST(JSON_VALUE(attributes, '$."gen_ai.usage.input_tokens"') AS INT64) as input_tokens,
    SAFE_CAST(JSON_VALUE(attributes, '$."gen_ai.usage.output_tokens"') AS INT64) AS output_tokens,
    SAFE_CAST(JSON_VALUE(attributes, '$."gen_ai.usage.experimental.reasoning_tokens"') AS INT64) AS experimental_reasoning_tokens,
    name as _name,
    JSON_VALUE(attributes, '$."gen_ai.operation.name"') AS operation_name,
    JSON_VALUE(attributes, '$."gen_ai.request.model"') AS model,
    JSON_VALUE(attributes, '$."gen_ai.agent.name"') AS agent_name,
    -- attributes['gen_ai.agent.name'] AS agent_name,
    ARRAY_TO_STRING(JSON_VALUE_ARRAY(attributes, '$."gen_ai.response.finish_reasons"'), '|') AS reason,

    JSON_QUERY(SAFE.PARSE_JSON(JSON_VALUE(attributes, '$."gcp.vertex.agent.llm_request"')), '$.contents[0].parts[0].text') AS llm_request_content1,
    JSON_QUERY(SAFE.PARSE_JSON(JSON_VALUE(attributes, '$."gcp.vertex.agent.llm_request"')), '$.contents[1].parts[0].function_call.name') AS llm_request_content2,
    JSON_QUERY(SAFE.PARSE_JSON(JSON_VALUE(attributes, '$."gcp.vertex.agent.llm_request"')), '$.contents[2].parts[0].function_response.response.result') AS llm_request_content3,
    JSON_QUERY(SAFE.PARSE_JSON(JSON_VALUE(attributes, '$."gcp.vertex.agent.llm_response"')), '$.content.parts[0].text') AS llm_response_text,
    TIMESTAMP_DIFF(end_time, start_time, MILLISECOND) AS duration_ms
FROM
    -- replace project-id with real project
    `project-id.global._Trace._AllSpans`
WHERE
    IFNULL(JSON_VALUE(attributes, '$."/component"'), '') != 'AppServer'
    AND IFNULL(JSON_VALUE(attributes, '$."/component"'), '') != 'HTTP load balancer'
    AND IFNULL(JSON_VALUE(attributes, '$."db.system"'), '') != 'BigQuery'
-- JSON_VALUE(attributes, '$."gen_ai.agent.name"') = 'my_bq_agent'
-- AND JSON_VALUE(attributes, '$."gen_ai.operation.name"') = 'generate_content'
-- AND JSON_VALUE(attributes, '$."gen_ai.request.model"') IS NOT NULL
ORDER BY _start_time, _trace_id
