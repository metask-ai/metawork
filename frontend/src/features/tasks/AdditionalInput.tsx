import type {
  AdditionalInputView,
  RunInputView,
  SendInputReason,
} from "../../bridge/contracts.ts";
import { useId } from "react";
import { Message } from "../../components/ai/Message.tsx";
import { CopyButton } from "../../components/ui/CopyButton.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { copyRunInput } from "./response-copy.ts";

const continuationReasonMessages = {
  binding_changed: "input.continuation.execution",
  binding_unavailable: "input.continuation.execution",
  task_unavailable: "input.continuation.unavailable",
  task_busy: "input.continuation.busy",
  workspace_unavailable: "input.continuation.workspace",
  workspace_changed: "input.continuation.workspace",
  workspace_removing: "input.continuation.workspace",
  catalog_loading: "input.continuation.capability",
  catalog_unavailable: "input.continuation.capability",
  stale_catalog: "input.continuation.capability",
  skill_not_found: "input.continuation.capability",
  skill_unavailable: "input.continuation.capability",
  invalid_skill_arguments: "input.continuation.input",
  missing_instruction: "input.continuation.input",
  unsupported_input: "input.continuation.input",
  unsupported_attachment: "input.continuation.input",
  capacity_reached: "input.continuation.capacity",
  shutting_down: "input.continuation.shutting_down",
  run_changed: "input.continuation.unavailable",
  run_not_ready: "input.continuation.unavailable",
  run_stopping: "input.continuation.unavailable",
  too_late: "input.continuation.unavailable",
  invalid_input: "input.continuation.input",
  resource_limit: "input.continuation.capacity",
  checkpoint_budget_required: "input.continuation.capacity",
  admission_failed: "input.continuation.failed",
  continuation_cancelled: "mutation.reason.continuation_cancelled",
  combined_input_too_large: "mutation.reason.combined_input_too_large",
  checkpoint_failed: "mutation.reason.checkpoint_failed",
  schedule_failed: "mutation.reason.schedule_failed",
} as const satisfies Record<SendInputReason, MessageId>;

export function AdditionalInput({
  input,
  latest = false,
  onRestore,
  onLocate,
}: {
  input: AdditionalInputView;
  latest?: boolean;
  onRestore: (input: RunInputView) => void;
  onLocate: (runId: string) => void;
}) {
  const { t } = useI18n();
  const statusId = useId();
  const textInput: RunInputView = {
    kind: "text",
    text: input.text,
    redacted: input.redacted,
  };
  return (
    <div
      className="additional-input"
      data-input-id={input.id}
      data-state={input.state}
    >
      <Message role="user" aria-describedby={statusId}>
        <p className="task-input-copy">{input.text}</p>
        {input.redacted && (
          <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
        )}
      </Message>
      <div className="additional-input-metadata">
        <div className="additional-input-actions">
          <p
            className="additional-input-state"
            id={statusId}
            aria-live="polite"
          >
            {t(`input.state.${input.state}`)}
          </p>
          <CopyButton
            className="input-copy-action"
            data-latest={latest}
            copyLabel={t("copy.input")}
            copiedLabel={t("copy.copied")}
            failedLabel={t("copy.failed")}
            onCopy={() => copyRunInput(textInput)}
          />
          {input.state === "transferred" && input.transferredToRunId && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="additional-input-target"
              onClick={() => onLocate(input.transferredToRunId!)}
            >
              {t("input.locate_target")}
            </Button>
          )}
        </div>
        {input.continuationReason && (
          <p className="projection-note">
            {t(continuationReasonMessages[input.continuationReason])}
          </p>
        )}
        {input.state === "adopted" && input.order === null && (
          <p className="projection-note">{t("input.position_unknown")}</p>
        )}
        {(input.state === "unadopted" || input.state === "unknown") && (
          <>
            {input.state === "unknown" && (
              <p className="projection-note">{t("input.restore_unknown")}</p>
            )}
            <Button
              type="button"
              className="additional-input-restore"
              variant="ghost"
              size="sm"
              onClick={() => onRestore(textInput)}
            >
              {t("input.restore")}
            </Button>
          </>
        )}
      </div>
    </div>
  );
}
