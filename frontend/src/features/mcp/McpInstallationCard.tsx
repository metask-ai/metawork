import { useEffect, useId, useState } from "react";
import type {
  McpInstallationOperation,
  McpMutationResult,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Input } from "../../components/ui/input.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

export type McpInstallationActions = {
  onCancelInstallation?: (
    id: string,
    revision: string,
  ) => Promise<McpMutationResult>;
  onCaptureInstallation?: (
    generation: string,
    id: string,
    slot: string,
    secret: string,
  ) => Promise<McpMutationResult>;
};

export function McpInstallationCard({
  operation,
  disabled = false,
  secretMaxBytes = 2560,
  onCancelInstallation,
  onCaptureInstallation,
}: McpInstallationActions & {
  operation: McpInstallationOperation;
  disabled?: boolean;
  secretMaxBytes?: number;
}) {
  const { t } = useI18n();
  const id = useId();
  const [value, setValue] = useState("");
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    setValue("");
    setFailed(false);
  }, [
    operation.serverId,
    operation.revision,
    operation.desiredGeneration,
    operation.phase,
  ]);
  const slot =
    operation.phase === "needs_credentials"
      ? operation.missingCredentials[0]
      : undefined;
  const phaseLabel = `mcp.install.phase.${operation.phase}` as MessageId;
  const failureLabel = operation.failure
    ? (`mcp.install.failure.${operation.failure}` as MessageId)
    : null;
  async function submit() {
    if (!slot || !onCaptureInstallation || pending || disabled) return;
    const secret = value;
    setValue("");
    setFailed(false);
    setPending(true);
    try {
      const result = await onCaptureInstallation(
        operation.desiredGeneration,
        operation.serverId,
        slot,
        secret,
      );
      if (
        result.outcome !== "saved" &&
        result.outcome !== "saved_recovery_required"
      )
        setFailed(true);
    } catch {
      setFailed(true);
    } finally {
      setPending(false);
    }
  }
  return (
    <section
      className="mcp-installation-card"
      aria-label={t("mcp.install.title")}
      aria-live="polite"
    >
      <strong>{operation.displayName}</strong>
      <p>{t(phaseLabel)}</p>
      {failureLabel && <p>{t(failureLabel)}</p>}
      <p>
        <code>{operation.sourceOrigin}</code>
        {operation.targetOrigin && (
          <>
            {" "}
            → <code>{operation.targetOrigin}</code>
          </>
        )}
      </p>
      {slot && (
        <form
          onSubmit={(event) => {
            event.preventDefault();
            void submit();
          }}
        >
          <label htmlFor={id}>{t("mcp.install.credential", { slot })}</label>
          <Input
            id={id}
            type="password"
            value={value}
            autoComplete="off"
            spellCheck={false}
            disabled={disabled || pending || !onCaptureInstallation}
            onChange={(event) => setValue(event.target.value)}
          />
          <Button
            type="submit"
            disabled={
              disabled ||
              pending ||
              !value ||
              !onCaptureInstallation ||
              new TextEncoder().encode(value).length > secretMaxBytes
            }
          >
            {t("mcp.install.submit")}
          </Button>
        </form>
      )}
      {failed && <p role="alert">{t("mcp.install.action_failed")}</p>}
      {operation.canCancel && (
        <Button
          variant="ghost"
          disabled={disabled || pending || !onCancelInstallation}
          onClick={async () => {
            setPending(true);
            setValue("");
            setFailed(false);
            try {
              const result = await onCancelInstallation?.(
                operation.serverId,
                operation.revision,
              );
              if (
                result &&
                result.outcome !== "saved" &&
                result.outcome !== "unchanged"
              )
                setFailed(true);
            } catch {
              setFailed(true);
            } finally {
              setPending(false);
            }
          }}
        >
          {t("mcp.install.cancel")}
        </Button>
      )}
    </section>
  );
}
