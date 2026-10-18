import type {
  AdditionalInputView,
  RunInputView,
} from "../../bridge/contracts.ts";
import { useId } from "react";
import { Message } from "../../components/ai/Message.tsx";
import { CopyButton } from "../../components/ui/CopyButton.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n } from "../../i18n/context.ts";
import { copyRunInput } from "./response-copy.ts";

export function AdditionalInput({
  input,
  latest = false,
  onRestore,
}: {
  input: AdditionalInputView;
  latest?: boolean;
  onRestore: (input: RunInputView) => void;
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
          <p className="additional-input-state" id={statusId}>
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
        </div>
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
