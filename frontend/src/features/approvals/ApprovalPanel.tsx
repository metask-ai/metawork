import { useState } from "react";
import { CodeBlock, Intervention } from "../../components/ai/index.ts";
import { Button } from "../../components/ui/button.tsx";
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
  const [expandedRequest, setExpandedRequest] = useState<string | null>(null);
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
  const shownTarget = target ?? fileCandidate?.target ?? null;
  const targetName = shownTarget?.split(/[\\/]/).at(-1) || shownTarget;
  const concern =
    task.approvalMode !== "manual" &&
    task.permissionReviewState === "needs_user" &&
    explanation?.cause === "reviewer_concern"
      ? explanation.reason
      : null;
  const detailsOpen = expandedRequest === pending.requestId;
  const detailsId = `ui-request-${pending.requestId}-details`;

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
      className="approval-panel"
      label={null}
      title={
        isCommand
          ? t("approval.action.command")
          : presentation
            ? t(`approval.action.${presentation.kind}`, {
                target: targetName ?? "",
              })
            : t("approval.allow_tool", { tool: pending.tool })
      }
      status={status}
    >
      {shownTarget !== null && <p className="approval-target">{shownTarget}</p>}
      {isCommand && (
        <p className="approval-purpose">
          <span>{t("approval.agent_purpose")}</span>{" "}
          {description || t("approval.purpose_unavailable")}
        </p>
      )}
      {command && (
        <CodeBlock aria-label={t("approval.command")} value={command} />
      )}
      {isCommand && !command && (
        <p className="approval-unavailable">
          {t("approval.command_unavailable")}
        </p>
      )}
      {concern && (
        <p className="approval-concern" role="status" aria-live="polite">
          <span>{t("approval.reviewer_note")}</span> {concern}
        </p>
      )}
      <div className="approval-footer">
        <button
          type="button"
          className="approval-details-toggle"
          aria-expanded={detailsOpen}
          aria-controls={detailsId}
          onClick={() =>
            setExpandedRequest(detailsOpen ? null : pending.requestId)
          }
        >
          {t(detailsOpen ? "approval.hide_request" : "approval.full_request")}
        </button>
        <div className="ai-intervention-actions">
          {choices.has("deny_once") && (
            <Button
              variant="secondary"
              size="lg"
              disabled={actionDisabled}
              onClick={() => respondPermission("deny_once")}
            >
              {t("approval.deny")}
            </Button>
          )}
          {!choices.has("allow_once") && choices.has("deny_session") && (
            <Button
              variant="secondary"
              size="lg"
              disabled={actionDisabled}
              onClick={() => respondPermission("deny_session")}
            >
              {denySessionLabel}
            </Button>
          )}
          {choices.has("allow_once") ? (
            <div className="approval-action-cluster" data-variant="primary">
              <Button
                className={
                  sessionChoiceAvailable ? "approval-split-main" : undefined
                }
                variant="primary"
                size="lg"
                disabled={actionDisabled}
                onClick={() => respondPermission("allow_once")}
              >
                {t("approval.allow_once")}
              </Button>
              {sessionChoiceAvailable && (
                <Menu.Root key={pending.requestId}>
                  <Menu.Trigger
                    className="approval-split-trigger"
                    aria-label={t("approval.more_allow_options")}
                    disabled={actionDisabled}
                  >
                    <Icon name="chevron" />
                  </Menu.Trigger>
                  <Menu.Portal>
                    <Menu.Positioner
                      side="top"
                      align="end"
                      collisionPadding={8}
                    >
                      <Menu.Popup
                        className="approval-choice-menu"
                        aria-label={t("approval.more_allow_options")}
                      >
                        {choices.has("allow_session") && (
                          <Menu.Item
                            className="approval-choice-menu-item"
                            onClick={() => respondPermission("allow_session")}
                          >
                            {allowSessionLabel}
                          </Menu.Item>
                        )}
                        {choices.has("deny_session") && (
                          <Menu.Item
                            className="approval-choice-menu-item"
                            onClick={() => respondPermission("deny_session")}
                          >
                            {denySessionLabel}
                          </Menu.Item>
                        )}
                        <div className="approval-choice-note">
                          <p>
                            {fileCandidate
                              ? t("approval.scope_file_session", {
                                  tool: pending.tool,
                                })
                              : t("approval.scope_session_available")}
                          </p>
                          {fileCandidate && <p>{fileCandidate.target}</p>}
                          <p>{t("approval.session_expiry")}</p>
                        </div>
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
      </div>
      {detailsOpen && (
        <div
          id={detailsId}
          className="approval-request-details"
          role="region"
          aria-label={t("approval.full_request")}
        >
          {pending.redacted && <p>{t("privacy.sensitive_hidden")}</p>}
          {!concern && (
            <p>
              {task.approvalMode === "manual"
                ? t("approval.manual_mode")
                : task.permissionReviewState === "needs_user"
                  ? t(`approval.handoff.${explanation?.cause ?? "unavailable"}`)
                  : t("approval.confirm_request")}
            </p>
          )}
          {explanation?.reason && !concern && (
            <p>
              {t("approval.reviewer_note")} {explanation.reason}
            </p>
          )}
          {isCommand && <p>{t("approval.command_effects")}</p>}
          <CodeBlock
            aria-label={t("approval.arguments")}
            value={pending.args}
          />
          <p>{t("approval.scope_once")}</p>
          {sessionChoiceAvailable && (
            <>
              <p>
                {fileCandidate
                  ? t("approval.scope_file_session", { tool: pending.tool })
                  : t("approval.scope_session_available")}
              </p>
              {fileCandidate && fileCandidate.target !== shownTarget && (
                <p>{fileCandidate.target}</p>
              )}
              <p>{t("approval.session_expiry")}</p>
            </>
          )}
          {diagnostic && (
            <aside className="approval-diagnostic" role="note">
              <strong>{t("approval.why_again")}</strong>
              <span>{t(`approval.reason_${diagnostic.reason}`)}</span>
              {diagnostic.restoreRulesInvalidated && (
                <span>{t("approval.restore_rules_invalidated")}</span>
              )}
            </aside>
          )}
        </div>
      )}
    </Intervention>
  );
}
