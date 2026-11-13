-- An approval change that crosses the Core profile boundary stops the Run for
-- a Product reason of its own, distinct from a user Stop.
ALTER TABLE runs DROP CONSTRAINT runs_cause_domain;
ALTER TABLE runs ADD CONSTRAINT runs_cause_domain CHECK(cause IS NULL OR cause IN ('user_cancel','approval_mode_change','timeout','session_close','app_shutdown','event_pipeline_failure','event_payload_too_large','queue_capacity_failure','ui_pipeline_failure','permission_required','agent_failure','provider_failure','tool_failure','image_input_unsupported','stale_catalog','skill_not_found','invalid_skill_arguments','skill_policy_violation','skill_unavailable','resource_limit','dependency_contract_failure'));
