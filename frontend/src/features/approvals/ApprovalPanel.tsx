import { CodeBlock, Intervention } from "../../components/ai/index.ts";
import { Button } from "../../components/ui/button.tsx";
import { DetailField } from "../../components/ui/detail-field.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import type {
  PendingUi,
  PermissionChoice,
  TaskView,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";
import { diagnoseRepeatedPermission } from "./permission-diagnostics.ts";
import type { UiResponsePhase } from "./response-state.ts";

export type FullAccessSuccessorAction = {
  phase: "ready" | "stopping";
  message: string | null;
  onContinue: () => void;
};

export function ApprovalPanel({
  pending,
  task,
  busy,
  responsePhase,
  fullAccessSuccessor,
  respond,
}: {
  pending: PendingUi;
  task: Pick<TaskView, "uiHistory" | "restorePermission">;
  busy: boolean;
  responsePhase: UiResponsePhase;
  fullAccessSuccessor?: FullAccessSuccessorAction | null;
  respond: (payload: UiResponsePayload) => void;
}) {
  const { t } = useI18n();
  const responseInFlight =
    responsePhase === "sending" || responsePhase === "awaiting_snapshot";
  const actionDisabled = busy || responseInFlight;
  const choices = new Set(pending.availableChoices);
  const sessionChoiceAvailable =
    choices.has("allow_session") || choices.has("deny_session");
  const diagnostic = diagnoseRepeatedPermission(task, pending);

  const respondPermission = (permission: PermissionChoice) =>
    respond({ kind: "permission", permission });

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
      <DetailField label={t("approval.scope")}>
        <p className="approval-scope-value">
          {sessionChoiceAvailable
            ? t("approval.scope_session_available")
            : t("approval.scope_once")}
        </p>
        {sessionChoiceAvailable && (
          <p className="approval-scope-expiry">
            {t("approval.session_expiry")}
          </p>
        )}
      </DetailField>
      {diagnostic && (
        <aside className="approval-diagnostic" role="note">
          <strong>{t("approval.why_again")}</strong>
          <span>{t(`approval.reason_${diagnostic.reason}`)}</span>
          {fullAccessSuccessor && (
            <div className="approval-successor-action">
              <Button
                variant="secondary"
                size="lg"
                disabled={
                  actionDisabled || fullAccessSuccessor.phase === "stopping"
                }
                onClick={fullAccessSuccessor.onContinue}
              >
                {fullAccessSuccessor.phase === "stopping"
                  ? t("approval.full_access_stopping")
                  : t("approval.full_access_continue")}
              </Button>
              {fullAccessSuccessor.message && (
                <span role="alert">{fullAccessSuccessor.message}</span>
              )}
            </div>
          )}
        </aside>
      )}
      <div className="ai-intervention-actions">
        {choices.has("deny_once") ? (
          <div className="approval-action-cluster" data-variant="secondary">
            <Button
              className="approval-split-main"
              variant="secondary"
              size="lg"
              disabled={actionDisabled}
              onClick={() => respondPermission("deny_once")}
            >
              {t("approval.deny")}
            </Button>
            {choices.has("deny_session") && (
              <Menu.Root>
                <Menu.Trigger
                  className="approval-split-trigger"
                  aria-label={t("approval.more_deny_options")}
                  disabled={actionDisabled}
                >
                  <Icon name="chevron" />
                </Menu.Trigger>
                <Menu.Portal>
                  <Menu.Positioner side="top" align="end" collisionPadding={8}>
                    <Menu.Popup
                      className="approval-choice-menu"
                      aria-label={t("approval.more_deny_options")}
                    >
                      <Menu.Item
                        className="approval-choice-menu-item"
                        onClick={() => respondPermission("deny_session")}
                      >
                        {t("approval.deny_session")}
                      </Menu.Item>
                    </Menu.Popup>
                  </Menu.Positioner>
                </Menu.Portal>
              </Menu.Root>
            )}
          </div>
        ) : (
          choices.has("deny_session") && (
            <Button
              variant="secondary"
              size="lg"
              disabled={actionDisabled}
              onClick={() => respondPermission("deny_session")}
            >
              {t("approval.deny_session")}
            </Button>
          )
        )}
        {choices.has("allow_once") ? (
          <div className="approval-action-cluster" data-variant="primary">
            <Button
              className="approval-split-main"
              variant="primary"
              size="lg"
              disabled={actionDisabled}
              onClick={() => respondPermission("allow_once")}
            >
              {t("approval.allow_once")}
            </Button>
            {choices.has("allow_session") && (
              <Menu.Root>
                <Menu.Trigger
                  className="approval-split-trigger"
                  aria-label={t("approval.more_allow_options")}
                  disabled={actionDisabled}
                >
                  <Icon name="chevron" />
                </Menu.Trigger>
                <Menu.Portal>
                  <Menu.Positioner side="top" align="end" collisionPadding={8}>
                    <Menu.Popup
                      className="approval-choice-menu"
                      aria-label={t("approval.more_allow_options")}
                    >
                      <Menu.Item
                        className="approval-choice-menu-item"
                        onClick={() => respondPermission("allow_session")}
                      >
                        {t("approval.allow_session")}
                      </Menu.Item>
                    </Menu.Popup>
                  </Menu.Positioner>
                </Menu.Portal>
              </Menu.Root>
            )}
          </div>
        ) : (
          choices.has("allow_session") && (
            <Button
              variant="primary"
              size="lg"
              disabled={actionDisabled}
              onClick={() => respondPermission("allow_session")}
            >
              {t("approval.allow_session")}
            </Button>
          )
        )}
      </div>
    </Intervention>
  );
}

export function FullAccessSuccessorNotice({
  phase,
  message,
  retry,
  dismiss,
}: {
  phase:
    | "stopping"
    | "stop_failed"
    | "creating"
    | "failed"
    | "outcome_unknown"
    | "syncing"
    | "sync_failed";
  message: string | null;
  retry: (() => void) | null;
  dismiss: (() => void) | null;
}) {
  const { t } = useI18n();
  return (
    <aside className="approval-successor-notice" role="status">
      <strong>
        {phase === "stopping"
          ? t("approval.full_access_stopping")
          : phase === "stop_failed"
            ? t("approval.full_access_stop_failed")
            : phase === "creating"
              ? t("approval.full_access_creating")
              : phase === "syncing" || phase === "sync_failed"
                ? t("approval.full_access_sync_pending")
                : phase === "outcome_unknown"
                  ? t("approval.full_access_outcome_unknown")
                  : t("approval.full_access_failed")}
      </strong>
      {message && <span>{message}</span>}
      {retry && (
        <Button variant="secondary" size="lg" onClick={retry}>
          {phase === "stop_failed"
            ? t("approval.full_access_retry_stop")
            : phase === "sync_failed"
              ? t("approval.full_access_retry_sync")
              : t("approval.full_access_retry")}
        </Button>
      )}
      {dismiss && (
        <Button variant="secondary" size="lg" onClick={dismiss}>
          {t("approval.full_access_dismiss")}
        </Button>
      )}
    </aside>
  );
}
