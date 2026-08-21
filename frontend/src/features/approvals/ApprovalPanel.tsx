import { CodeBlock } from "../../components/ai/index.ts";
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

  return (
    <section
      id={`ui-request-${pending.requestId}`}
      tabIndex={-1}
      className="inline-request"
      aria-busy={responseInFlight}
    >
      <p className="font-mono text-(length:--text-micro) tracking-[0.14em] text-ui-warning uppercase">
        {t("approval.response_required")}
      </p>
      {pending.redacted && (
        <p className="projection-note" role="note">
          {t("privacy.sensitive_hidden")}
        </p>
      )}
      <div className="mt-4">
        <h3 className="font-semibold">
          {t("approval.allow_tool", { tool: pending.tool })}
        </h3>
        <DetailField label={t("approval.arguments")}>
          <CodeBlock value={pending.args} />
        </DetailField>
        <div className="mt-4 grid grid-cols-2 gap-2">
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
                className="decision-button"
                data-primary={
                  choice === "allow_once" || choice === "allow_session"
                }
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
      </div>
      {responsePhase !== "idle" && (
        <p
          className="request-response-status"
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
      )}
    </section>
  );
}
