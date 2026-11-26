import { useCallback, useEffect, useRef, useState, type Ref } from "react";
import type {
  GlobalInstructionsSaveOutcome,
  GlobalInstructionsSaveResult,
  GlobalInstructionsView,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

export type GlobalInstructionsActions = {
  read: () => Promise<GlobalInstructionsView>;
  save: (
    expectedRevision: string,
    text: string,
  ) => Promise<GlobalInstructionsSaveResult>;
};

type Load =
  | { status: "loading" }
  | { status: "failed" }
  | { status: "loaded"; view: GlobalInstructionsView };

type Notice =
  | { kind: "saved" }
  | { kind: "conflict"; revision: string }
  | { kind: "failed"; outcome: GlobalInstructionsSaveOutcome | "transport" };

const encoder = new TextEncoder();

/** A textarea reports every line break as LF, whatever the file held. */
function normalizeLineBreaks(text: string) {
  return text.replace(/\r\n?/g, "\n");
}

/**
 * The file's own line break: CRLF when the loaded text used it, LF
 * otherwise. A save writes the edited text back in that style, so editing
 * a CRLF file in MetaWork does not rewrite every line of it.
 */
function lineBreakOf(text: string) {
  return text.includes("\r\n") ? "\r\n" : "\n";
}

const stateMessages: Partial<
  Record<GlobalInstructionsView["state"], MessageId>
> = {
  unavailable: "settings.instructions.unavailable",
  too_large: "settings.instructions.too_large_to_edit",
  unreadable: "settings.instructions.unreadable",
  contains_credential: "settings.instructions.contains_credential",
};

const failureMessages: Record<
  GlobalInstructionsSaveOutcome | "transport",
  MessageId
> = {
  saved: "settings.instructions.save_failed",
  conflict: "settings.instructions.save_failed",
  too_large: "settings.instructions.over_limit",
  invalid_text: "settings.instructions.invalid_text",
  contains_credential: "settings.instructions.save_contains_credential",
  write_failed: "settings.instructions.save_failed",
  unavailable: "settings.instructions.unavailable",
  transport: "settings.instructions.save_failed",
};

/**
 * The global instructions file, read and saved only through the Host. The
 * Host's answers are the truth: nothing here assumes a save happened until
 * the Host says so, and an outside change is shown before anything
 * overwrites it.
 */
export function GlobalInstructionsSettings({
  actions,
  disabled,
  headingRef,
}: {
  actions: GlobalInstructionsActions;
  disabled: boolean;
  headingRef?: Ref<HTMLHeadingElement>;
}) {
  const { t } = useI18n();
  const [load, setLoad] = useState<Load>({ status: "loading" });
  const [draft, setDraft] = useState("");
  const [saved, setSaved] = useState("");
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState<Notice | null>(null);
  const generation = useRef(0);

  const reload = useCallback(async () => {
    const current = ++generation.current;
    setLoad({ status: "loading" });
    try {
      const view = await actions.read();
      if (current !== generation.current) return;
      setLoad({ status: "loaded", view });
      setDraft(view.text ?? "");
      setSaved(view.text ?? "");
      setNotice(null);
    } catch {
      if (current !== generation.current) return;
      setLoad({ status: "failed" });
    }
  }, [actions]);

  useEffect(() => {
    void reload();
    return () => {
      generation.current += 1;
    };
  }, [reload]);

  const view = load.status === "loaded" ? load.view : null;
  const editable =
    view !== null && (view.state === "ready" || view.state === "absent");
  // What a save would write: the edited text in the file's own line breaks.
  const outgoing = normalizeLineBreaks(draft).replaceAll(
    "\n",
    lineBreakOf(saved),
  );
  const bytes = encoder.encode(outgoing).length;
  const overLimit = view !== null && bytes > view.limitBytes;
  const changed = normalizeLineBreaks(draft) !== normalizeLineBreaks(saved);

  async function save(expectedRevision: string) {
    if (view === null) return;
    setSaving(true);
    setNotice(null);
    const text = outgoing;
    try {
      const result = await actions.save(expectedRevision, text);
      if (result.outcome === "saved") {
        setLoad({
          status: "loaded",
          view: {
            ...view,
            state: "ready",
            text,
            revision: result.revision,
          },
        });
        setSaved(text);
        setNotice({ kind: "saved" });
      } else if (result.outcome === "conflict") {
        setNotice({ kind: "conflict", revision: result.revision ?? "absent" });
      } else {
        setNotice({ kind: "failed", outcome: result.outcome });
      }
    } catch {
      setNotice({ kind: "failed", outcome: "transport" });
    } finally {
      setSaving(false);
    }
  }

  return (
    <section id="settings-instructions" className="settings-section">
      <div className="settings-section-heading">
        <h2 ref={headingRef} tabIndex={-1}>
          {t("settings.instructions")}
        </h2>
      </div>
      <div className="settings-group">
        <h3 className="settings-group-label">
          {t("settings.instructions.global")}
        </h3>
        <div className="settings-instructions">
          <p>{t("settings.instructions.help")}</p>
          {view?.path ? (
            <code className="settings-instructions-path" title={view.path}>
              {view.path}
            </code>
          ) : null}
          {load.status === "loading" ? (
            <p role="status">{t("settings.instructions.loading")}</p>
          ) : null}
          {load.status === "failed" ? (
            <div className="settings-instructions-notice" role="alert">
              <p className="settings-instructions-error">
                {t("settings.instructions.load_failed")}
              </p>
              <Button
                variant="secondary"
                size="sm"
                disabled={disabled}
                onClick={() => void reload()}
              >
                {t("settings.instructions.reload")}
              </Button>
            </div>
          ) : null}
          {view !== null && stateMessages[view.state] ? (
            <p className="settings-instructions-error" role="status">
              {t(stateMessages[view.state]!, {
                size: view.byteLength ?? "",
              })}
            </p>
          ) : null}
          {view !== null && editable ? (
            <>
              {view.state === "absent" ? (
                <p>{t("settings.instructions.absent")}</p>
              ) : null}
              <textarea
                className="settings-instructions-editor focus-ring"
                aria-label={t("settings.instructions.global")}
                aria-describedby="settings-instructions-size"
                value={draft}
                spellCheck={false}
                disabled={disabled || saving}
                onChange={(event) => {
                  setDraft(event.currentTarget.value);
                  if (notice?.kind === "saved") setNotice(null);
                }}
              />
              <div className="settings-instructions-meta">
                <span
                  id="settings-instructions-size"
                  className={overLimit ? "settings-instructions-error" : ""}
                >
                  {t("settings.instructions.size", {
                    bytes: String(bytes),
                    limit: String(view.limitBytes),
                  })}
                </span>
                <Button
                  variant="primary"
                  size="sm"
                  disabled={
                    disabled ||
                    saving ||
                    !changed ||
                    overLimit ||
                    view.revision === null
                  }
                  onClick={() => void save(view.revision!)}
                >
                  {saving
                    ? t("settings.instructions.saving")
                    : t("settings.instructions.save")}
                </Button>
              </div>
              {overLimit ? (
                <p className="settings-instructions-error" role="alert">
                  {t("settings.instructions.over_limit")}
                </p>
              ) : null}
            </>
          ) : null}
          {notice?.kind === "saved" ? (
            <p role="status">{t("settings.instructions.saved")}</p>
          ) : null}
          {notice?.kind === "failed" ? (
            <p className="settings-instructions-error" role="alert">
              {t(failureMessages[notice.outcome])}
            </p>
          ) : null}
          {notice?.kind === "conflict" ? (
            <div className="settings-instructions-notice" role="alert">
              <p className="settings-instructions-error">
                {t("settings.instructions.conflict")}
              </p>
              <div className="settings-instructions-actions">
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={disabled || saving}
                  onClick={() => void reload()}
                >
                  {t("settings.instructions.reload")}
                </Button>
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={disabled || saving || overLimit}
                  onClick={() => void save(notice.revision)}
                >
                  {t("settings.instructions.overwrite")}
                </Button>
              </div>
            </div>
          ) : null}
        </div>
      </div>
    </section>
  );
}
