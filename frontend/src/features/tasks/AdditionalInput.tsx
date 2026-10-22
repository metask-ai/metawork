import type {
  AdditionalInputView,
  RunInputView,
} from "../../bridge/contracts.ts";
import { Message } from "../../components/ai/Message.tsx";
import { MessageInfoBar } from "./MessageInfoBar.tsx";
import type { RunTimestamp } from "./run-presentation.ts";
import { useI18n } from "../../i18n/context.ts";
import { copyRunInput } from "./response-copy.ts";

export function AdditionalInput({
  input,
  latest = false,
  submittedTime,
}: {
  input: AdditionalInputView;
  latest?: boolean;
  submittedTime?: RunTimestamp | null;
}) {
  const { t } = useI18n();
  const textInput: RunInputView = {
    kind: "text",
    text: input.text,
    redacted: input.redacted,
  };
  return (
    <div className="additional-input" data-input-id={input.id}>
      <Message role="user" tabIndex={-1} className="focus-ring">
        <p className="task-input-copy">{input.text}</p>
        {input.redacted && (
          <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
        )}
      </Message>
      <MessageInfoBar
        role="user"
        time={submittedTime}
        latest={latest}
        onCopy={() => copyRunInput(textInput)}
      />
    </div>
  );
}
