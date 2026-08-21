import { CodeBlock, Intervention } from "../../components/ai/index.ts";
import { Button } from "../../components/ui/button.tsx";
import { DetailField } from "../../components/ui/detail-field.tsx";
import type { PendingUi, UiResponsePayload } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";
import type { UiResponsePhase } from "./response-state.ts";

export function ApprovalPanel({
  pending,
  busy,
  responsePhase,
  respond,
}: {
  pending: PendingUi;
  busy: boolean;
  responsePhase: UiResponsePhase;
  respond: (payload: UiResponsePayload) => void;
}) {
  const { t } = useI18n();
  const responseInFlight =
    responsePhase === "sending" || responsePhase === "awaiting_snapshot";
  const actionDisabled = busy || responseInFlight;

  const status =
    responsePhase === "idle" ? null : (
      <p
        data-phase={responsePhase}
        role={responsePhase === "failed" ? "alert" : "status"}
        aria-live={responsePhase === "failed" ? "assertive" : "polite"}
      >
        {responsePhase === "sending"
          ? t("approval.sending")
          : responsePhase === "awaiting_snapshot"
            ? t("approval.awaiting_snapshot")
            : t("approval.retry_response")}
      </p>
    );

  return (
    <Intervention
      id={`ui-request-${pending.requestId}`}
      tabIndex={-1}
      kind="permission"
      busy={responseInFlight}
      label={t("approval.response_required")}
      title={t("approval.allow_tool", { tool: pending.tool })}
      status={status}
    >
      {pending.redacted && (
        <p className="projection-note" role="note">
          {t("privacy.sensitive_hidden")}
        </p>
      )}
      <DetailField label={t("approval.arguments")}>
        <CodeBlock value={pending.args} />
      </DetailField>
      <div className="ai-intervention-actions">
        {(pending.availableChoices ?? ["deny_once", "allow_once"]).map(
          (choice) => (
            <Button
              key={choice}
              variant={
                choice === "allow_once" || choice === "allow_session"
                  ? "primary"
                  : "secondary"
              }
              size="md"
              disabled={actionDisabled}
              onClick={() =>
                respond({ kind: "permission", permission: choice })
              }
            >
              {choice === "deny_once"
                ? t("approval.deny")
                : choice === "allow_once"
                  ? t("approval.allow_once")
                  : choice === "allow_session"
                    ? t("approval.allow_session")
                    : t("approval.deny_session")}
            </Button>
          ),
        )}
      </div>
    </Intervention>
  );
}
