import type { WorkbenchConnectionStatus } from "../bridge/connection.ts";
import type { MessageId } from "../i18n/context.ts";
import {
  attentionStatus,
  quietStatus,
  type ShellStatus,
} from "./command-bar-status.ts";

export type ConnectionFailurePresentation = {
  titleId: MessageId;
  helpId: MessageId;
  retryable: boolean;
};

export function connectionStatus(
  status: WorkbenchConnectionStatus,
): ShellStatus {
  if (status.kind === "recovering")
    return quietStatus("connection.sync_retrying", { scope: "connection" });
  if (status.kind === "connected")
    return quietStatus(
      status.recovered ? "connection.recovered" : "connection.connected",
      { scope: "connection" },
    );
  if (status.kind === "refresh_failed")
    return attentionStatus(
      "connection.refresh_failed",
      { scope: "connection" },
      { diagnostic: status.diagnostic },
    );

  if (status.kind === "connection_failed")
    return attentionStatus(
      "connection.failed",
      { scope: "connection" },
      { diagnostic: status.diagnostic },
    );

  const componentMismatch =
    status.source === "bootstrap" &&
    (status.code === "identity_mismatch" ||
      status.code === "revision_mismatch");
  return attentionStatus(
    componentMismatch
      ? "connection.component_mismatch"
      : "connection.contract_failed",
    { scope: "connection" },
    {
      diagnostic: status.diagnostic,
      sourceId: `connection.source.${status.source}`,
    },
  );
}

export function connectionFailurePresentation(
  status: ShellStatus | undefined,
): ConnectionFailurePresentation {
  if (status?.id === "connection.component_mismatch")
    return {
      titleId: "connection.component_mismatch",
      helpId: "connection.component_mismatch_help",
      retryable: false,
    };
  if (status?.id === "connection.contract_failed")
    return {
      titleId: "connection.contract_failed",
      helpId: "connection.contract_failed_help",
      retryable: true,
    };
  return {
    titleId: "connection.failed",
    helpId: "connection.failed_help",
    retryable: true,
  };
}
