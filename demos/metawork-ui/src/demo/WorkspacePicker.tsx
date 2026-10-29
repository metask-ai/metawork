import { useRef, useState, useSyncExternalStore } from "react";
import { Dialog } from "../components/ui/dialog.tsx";
import { Button } from "../components/ui/button.tsx";
import { Input } from "../components/ui/input.tsx";
import { Icon } from "../components/ui/Icon.tsx";
import { useI18n } from "../i18n/context.ts";
import { demo } from "./state.ts";
import {
  addDemoWorkspace,
  cancelDemoWorkspace,
  getWorkspacePickerRequest,
  normalizeDemoWorkspaceName,
  selectDemoWorkspace,
  subscribeWorkspacePicker,
} from "./workspace-picker.ts";

export function DemoWorkspacePicker() {
  const request = useSyncExternalStore(
    subscribeWorkspacePicker,
    getWorkspacePickerRequest,
  );
  return request ? <WorkspacePickerDialog key={request.id} /> : null;
}

function WorkspacePickerDialog() {
  const { t } = useI18n();
  const [name, setName] = useState("");
  const [failed, setFailed] = useState(false);
  const nameInput = useRef<HTMLInputElement>(null);
  const normalized = normalizeDemoWorkspaceName(name);
  const invalid = !!name.trim() && !normalized;
  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open) cancelDemoWorkspace();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup
          className="demo-workspace-picker"
          initialFocus={nameInput}
        >
          <div className="demo-workspace-picker-heading">
            <Dialog.Title>{t("workspace.select")}</Dialog.Title>
            <Dialog.Close
              aria-label={t("common.close")}
              className="demo-workspace-picker-close"
            >
              <Icon name="close" />
            </Dialog.Close>
          </div>
          <Dialog.Description>当前 demo 仅模拟界面交互。</Dialog.Description>
          <div
            className="demo-workspace-picker-list"
            role="group"
            aria-label={t("workspace.label")}
          >
            {demo.workspaces
              .filter((workspace) => workspace.kind === "manual")
              .map((workspace) => (
                <Button
                  key={workspace.id}
                  variant="ghost"
                  className="demo-workspace-picker-option"
                  disabled={workspace.authorization !== "available"}
                  onClick={() => {
                    if (!selectDemoWorkspace(workspace.id)) setFailed(true);
                  }}
                >
                  <Icon name="workspace" />
                  <span>
                    <strong>{workspace.displayName}</strong>
                    <small>{workspace.canonicalRoot}</small>
                  </span>
                </Button>
              ))}
          </div>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              if (!addDemoWorkspace(name)) setFailed(true);
            }}
          >
            <label htmlFor="demo-workspace-name">{t("mcp.add.name")}</label>
            <Input
              ref={nameInput}
              id="demo-workspace-name"
              value={name}
              maxLength={80}
              autoComplete="off"
              required
              aria-invalid={invalid || failed || undefined}
              aria-describedby="demo-workspace-path"
              onChange={(event) => {
                setName(event.target.value);
                setFailed(false);
              }}
            />
            <p id="demo-workspace-path" className="demo-workspace-picker-path">
              /Demo/{normalized ?? ""}
            </p>
            {(invalid || failed) && (
              <p role="alert">{t("workspace.selection_failed")}</p>
            )}
            <div className="demo-workspace-picker-actions">
              <Button
                variant="ghost"
                type="button"
                onClick={cancelDemoWorkspace}
              >
                {t("common.cancel")}
              </Button>
              <Button type="submit" disabled={!normalized}>
                {t("workspace.add")}
              </Button>
            </div>
          </form>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
