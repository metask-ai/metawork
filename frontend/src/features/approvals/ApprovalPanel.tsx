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

export function ApprovalPanel({
  pending,
  task,
  busy,
  responsePhase,
  respond,
}: {
  pending: PendingUi;
  task: Pick<
    TaskView,
    | "uiHistory"
    | "restorePermission"
    | "permissionReviewState"
    | "permissionReviewExplanation"
    | "approvalMode"
  >;
  busy: boolean;
  responsePhase: UiResponsePhase;
  respond: (payload: UiResponsePayload) => void;
}) {
  const { t } = useI18n();
  if (task.permissionReviewState === "reviewing") return null;

  const responseInFlight =
    responsePhase === "sending" || responsePhase === "awaiting_snapshot";
  const actionDisabled = busy || responseInFlight;
  const choices = new Set(pending.availableChoices);
  const sessionChoiceAvailable =
    choices.has("allow_session") || choices.has("deny_session");
  const fileCandidate =
    pending.candidate?.scope === "file_target" ? pending.candidate : null;
  const allowSessionLabel = t(
    fileCandidate ? "approval.allow_session_file" : "approval.allow_session",
  );
  const denySessionLabel = t(
    fileCandidate ? "approval.deny_session_file" : "approval.deny_session",
  );
  const diagnostic = diagnoseRepeatedPermission(task, pending);
  const presentation = pending.presentation;
  const isCommand =
    pending.toolNamespace === "builtin" && pending.tool === "Bash";
  const command =
    presentation?.kind === "command" ? presentation.command : null;
  const description =
    presentation?.kind === "command" ? presentation.description : null;
  const target =
    presentation && presentation.kind !== "command"
      ? presentation.target
      : null;
  const explanation = task.permissionReviewExplanation;

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
      title={
        isCommand
          ? t("approval.action.command")
          : presentation
            ? t(`approval.action.${presentation.kind}`)
            : t("approval.allow_tool", { tool: pending.tool })
      }
      status={status}
    >
      {pending.redacted && (
        <p className="projection-note" role="note">
          {t("privacy.sensitive_hidden")}
        </p>
      )}
      <DetailField label={t("approval.confirmation_reason")}>
        <p
          className="approval-scope-value"
          role={
            responsePhase === "idle" &&
            task.permissionReviewState === "needs_user" &&
            task.approvalMode !== "manual"
              ? "status"
              : undefined
          }
          aria-live={
            responsePhase === "idle" &&
            task.permissionReviewState === "needs_user" &&
            task.approvalMode !== "manual"
              ? "polite"
              : undefined
          }
        >
          {task.approvalMode === "manual"
            ? t("approval.manual_mode")
            : task.permissionReviewState === "needs_user"
              ? t(`approval.handoff.${explanation?.cause ?? "unavailable"}`)
              : t("approval.confirm_request")}
        </p>
      </DetailField>
      {explanation?.reason && (
        <DetailField label={t("approval.reviewer_note")}>
          <p className="approval-scope-value">{explanation.reason}</p>
        </DetailField>
      )}
      {isCommand && (
        <DetailField label={t("approval.agent_purpose")}>
          <p className="approval-scope-value">
            {description || t("approval.purpose_unavailable")}
          </p>
        </DetailField>
      )}
      {target !== null && (
        <DetailField
          label={t(
            presentation?.kind === "web_fetch"
              ? "approval.target_url"
              : "approval.target_file",
          )}
        >
          <p className="approval-scope-value">{target}</p>
        </DetailField>
      )}
      {command ? (
        <DetailField label={t("approval.command")}>
          <CodeBlock value={command} />
          <p className="approval-scope-expiry">
            {t("approval.command_effects")}
          </p>
        </DetailField>
      ) : !presentation || isCommand ? (
        <DetailField label={t("approval.arguments")}>
          {isCommand && (
            <p className="approval-scope-expiry">
              {t("approval.command_unavailable")}
            </p>
          )}
          <CodeBlock value={pending.args} />
          {isCommand && (
            <p className="approval-scope-expiry">
              {t("approval.command_effects")}
            </p>
          )}
        </DetailField>
      ) : null}
      {presentation && (!isCommand || command) && (
        <details className="approval-request-details">
          <summary>{t("approval.full_request")}</summary>
          <CodeBlock value={pending.args} />
        </details>
      )}
      <DetailField label={t("approval.scope")}>
        <p className="approval-scope-value">
          {sessionChoiceAvailable
            ? fileCandidate
              ? t("approval.scope_file_session", { tool: pending.tool })
              : t("approval.scope_session_available")
            : t("approval.scope_once")}
        </p>
        {fileCandidate && fileCandidate.target !== target && (
          <p className="approval-scope-value">{fileCandidate.target}</p>
        )}
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
          {diagnostic.restoreRulesInvalidated && (
            <span>{t("approval.restore_rules_invalidated")}</span>
          )}
        </aside>
      )}
      <div className="ai-intervention-actions">
        {choices.has("deny_once") ? (
          <div className="approval-action-cluster" data-variant="secondary">
            <Button
              className={
                choices.has("deny_session") ? "approval-split-main" : undefined
              }
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
                        {denySessionLabel}
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
              {denySessionLabel}
            </Button>
          )
        )}
        {choices.has("allow_once") ? (
          <div className="approval-action-cluster" data-variant="primary">
            <Button
              className={
                choices.has("allow_session") ? "approval-split-main" : undefined
              }
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
                        {allowSessionLabel}
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
              {allowSessionLabel}
            </Button>
          )
        )}
      </div>
    </Intervention>
  );
}
