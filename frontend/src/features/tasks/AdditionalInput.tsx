import { UserInputMessage } from "./UserInputMessage.tsx";
import type {
  AdditionalInputView,
  RunInputView,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { MessageInfoBar } from "./MessageInfoBar.tsx";
import type { RunTimestamp } from "./run-presentation.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { copyRunInput } from "./response-copy.ts";

// A batch a Task mutation retired is resent through the same surface as a
// failed submission.
export type AdditionalInputResend = {
  retryDisabled: boolean;
  discardDisabled: boolean;
  onRetry: () => void;
  onDiscard: () => void;
};

export function AdditionalInput({
  input,
  latest = false,
  submittedTime,
  resend,
}: {
  input: AdditionalInputView;
  latest?: boolean;
  submittedTime?: RunTimestamp | null;
  resend?: AdditionalInputResend;
}) {
  const { t } = useI18n();
  const textInput: RunInputView = {
    kind: "text",
    text: input.text,
    redacted: input.redacted,
  };
  return (
    <UserInputMessage
      operationId={input.operationId}
      inputId={input.id}
      footer={
        <MessageInfoBar
          role="user"
          time={submittedTime}
          latest={latest}
          onCopy={() => copyRunInput(textInput)}
        />
      }
      notice={
        input.retryAvailable && resend ? (
          <>
            {input.continuationReason && (
              <p className="projection-note">
                {t(`mutation.reason.${input.continuationReason}` as MessageId)}
              </p>
            )}
            <Button
              type="button"
              size="sm"
              variant="secondary"
              disabled={resend.retryDisabled}
              onClick={resend.onRetry}
            >
              {t("input.retry_original")}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={resend.discardDisabled}
              onClick={resend.onDiscard}
            >
              {t("input.discard_retry")}
            </Button>
          </>
        ) : undefined
      }
    >
      <p className="task-input-copy">{input.text}</p>
      {input.redacted && (
        <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
      )}
    </UserInputMessage>
  );
}
