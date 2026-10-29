import { useState, useSyncExternalStore } from "react";
import type { SkillImportPreview } from "../bridge/contracts.ts";
import { Dialog } from "../components/ui/dialog.tsx";
import { Button } from "../components/ui/button.tsx";
import { Icon } from "../components/ui/Icon.tsx";
import { useI18n } from "../i18n/context.ts";
import { resolveSkillRoot, validateSkillPackage } from "./uiux-logic.ts";

type Request = { id: number; kind: "package" | "directory" };
let sequence = 0;
let pending: {
  request: Request;
  resolve: (value: SkillImportPreview) => void;
  reject: (error: Error) => void;
} | null = null;
const sources = new Map<
  string,
  { root: string; nested: boolean; kind: "package" | "directory" }
>();
export const getDemoSkillSource = (id: string) => sources.get(id);
const subscribers = new Set<() => void>();
const subscribe = (fn: () => void) => {
  subscribers.add(fn);
  return () => {
    subscribers.delete(fn);
  };
};
const getRequest = () => pending?.request ?? null;
const publish = () => subscribers.forEach((fn) => fn());
export function requestDemoSkillImport(
  kind: "package" | "directory",
): Promise<SkillImportPreview> {
  if (pending) return Promise.resolve({ selected: false });
  return new Promise((resolve, reject) => {
    pending = { request: { id: ++sequence, kind }, resolve, reject };
    publish();
  });
}
function cancel() {
  const current = pending;
  pending = null;
  publish();
  current?.resolve({ selected: false });
}
export function DemoSkillPicker() {
  const request = useSyncExternalStore(subscribe, getRequest);
  return request ? (
    <SkillPickerDialog key={request.id} request={request} />
  ) : null;
}
function SkillPickerDialog({ request }: { request: Request }) {
  const { t } = useI18n();
  const [selected, setSelected] = useState(0);
  const files =
    request.kind === "directory"
      ? ["design-review/", "download/design-review/", "broken-skill/"]
      : ["design-review.skill", "design-review.zip", "design-review.txt"];
  const nested = request.kind === "directory" && selected === 1;
  function confirm() {
    const current = pending;
    if (!current) return;
    try {
      if (request.kind === "package") validateSkillPackage(files[selected]!);
      else
        resolveSkillRoot(
          selected === 2
            ? ["README.md"]
            : [
                `${files[selected]}SKILL.md`,
                `${files[selected]}references/checklist.md`,
              ],
        );
      const previewId = String(request.id);
      sources.set(previewId, {
        kind: request.kind,
        root:
          request.kind === "directory"
            ? `${files[selected]}SKILL.md`
            : files[selected]!,
        nested,
      });
      pending = null;
      publish();
      current.resolve({
        selected: true,
        previewId,
        sourceKind:
          request.kind === "directory" ? "local_directory" : "local_package",
        invocationName: "design-review",
        displayName: "design-review",
        description: "检查界面层级、交互反馈与视觉一致性。",
        fileCount: 3,
        totalBytes: 2048,
      });
    } catch (error) {
      pending = null;
      publish();
      current.reject(
        error instanceof Error ? error : new Error("SKILL_DEFINITION_MISSING"),
      );
    }
  }
  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open) cancel();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup className="demo-workspace-picker demo-skill-picker">
          <div className="demo-workspace-picker-heading">
            <Dialog.Title>
              {t(
                request.kind === "package"
                  ? "skills.choose_package"
                  : "skills.choose_folder",
              )}
            </Dialog.Title>
            <Dialog.Close
              className="demo-workspace-picker-close"
              aria-label={t("common.close")}
            >
              <Icon name="close" />
            </Dialog.Close>
          </div>
          <Dialog.Description>当前 demo 仅模拟界面交互。</Dialog.Description>
          <p className="demo-skill-formats">{t("demo.import_formats")}</p>
          <div
            className="demo-skill-fixtures"
            role="group"
            aria-label={t("demo.skill_fixture_label")}
          >
            {files.map((file, index) => (
              <button
                key={file}
                type="button"
                className="focus-ring"
                aria-pressed={selected === index}
                onClick={() => setSelected(index)}
              >
                <Icon
                  name={request.kind === "directory" ? "workspace" : "package"}
                />
                <span>{file}</span>
                {selected === index && <Icon name="check" />}
              </button>
            ))}
          </div>
          {nested && (
            <p className="skill-import-hint" role="status">
              {t("demo.import_nested")} · download/design-review/SKILL.md
            </p>
          )}
          <div className="demo-workspace-picker-actions">
            <Button variant="ghost" onClick={cancel}>
              {t("common.cancel")}
            </Button>
            <Button onClick={confirm}>{t("skills.import")}</Button>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
