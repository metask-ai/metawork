import type {
  AdditionalInputView,
  RunInputView,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { useI18n } from "../../i18n/context.ts";

export function AdditionalInputs({
  inputs,
  onRestore,
}: {
  inputs: AdditionalInputView[];
  onRestore: (input: RunInputView) => void;
}) {
  const { t } = useI18n();
  if (inputs.length === 0) return null;
  return (
    <section className="additional-inputs" aria-label={t("input.label")}>
      {inputs.map((input) => (
        <article
          key={input.id}
          className="additional-input"
          data-state={input.state}
        >
          <p className="additional-input-state">
            {t(`input.state.${input.state}`)}
          </p>
          <div className="additional-input-text">{input.text}</div>
          {input.redacted && (
            <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
          )}
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
                variant="secondary"
                size="sm"
                onClick={() =>
                  onRestore({
                    kind: "text",
                    text: input.text,
                    redacted: input.redacted,
                  })
                }
              >
                {t("input.restore")}
              </Button>
            </>
          )}
        </article>
      ))}
    </section>
  );
}
