-- Remove runtime-only reasons accepted by the previous history schema.
UPDATE task_input_submissions
SET payload = json_remove(payload, '$.failure_reason')
WHERE json_extract(payload, '$.state') = 'failed'
  AND json_extract(payload, '$.blocking_task_id') IS NULL
  AND json_extract(payload, '$.failure_reason') IN (
    'models_catalog_loading', 'task_busy', 'unsupported_attachment',
    'run_changed', 'run_not_ready', 'run_stopping', 'too_late',
    'continuation_cancelled', 'combined_input_too_large', 'checkpoint_failed', 'schedule_failed'
  );
