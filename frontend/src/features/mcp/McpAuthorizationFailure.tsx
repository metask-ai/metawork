import type { McpAuthorizationFailure } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

/**
 * Which OAuth step failed and why, including what the remote server said.
 * Remote text is shown verbatim as data, never as markup.
 */
export function McpAuthorizationFailureDetail({
  failure,
}: {
  failure: McpAuthorizationFailure;
}) {
  const { t } = useI18n();
  const remote =
    failure.error !== null && failure.errorDescription !== null
      ? `${failure.error}: ${failure.errorDescription}`
      : (failure.error ?? failure.errorDescription);
  return (
    <div className="mcp-authorization-failure">
      <p>
        {t("mcp.authorization_failure.summary", {
          step: t(`mcp.authorization_failure.step.${failure.step}`),
          reason: t(`mcp.authorization_failure.reason.${failure.reason}`),
        })}
        {failure.httpStatus !== null &&
          ` ${t("mcp.authorization_failure.http_status", { status: failure.httpStatus })}`}
      </p>
      {remote !== null && (
        <p>
          {t("mcp.authorization_failure.remote")} <code>{remote}</code>
        </p>
      )}
    </div>
  );
}
