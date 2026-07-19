import type { UiRecord } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

export function UiRecordCard({ record }: { record: UiRecord }) {
  const { t } = useI18n();
  return (
    <section className="ui-record" data-state={record.state}>
      <div>
        <p>{t(`ui.kind.${record.kind}`)}</p>
        <strong>{t(`ui.state.${record.state}`)}</strong>
      </div>
      {record.detail && <p>{record.detail}</p>}
      {(record.detailTruncated || record.redacted) && (
        <span>
          {record.redacted
            ? t("privacy.sensitive_hidden")
            : t("tool.output_shortened")}
        </span>
      )}
    </section>
  );
}
