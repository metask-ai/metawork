import { useRef, useState, type ReactNode } from "react";
import type { WorkspaceView } from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import {
  createContextMenuAnchor,
  type ContextMenuAnchor,
} from "../../components/ui/context-menu-anchor.ts";
import { useI18n } from "../../i18n/context.ts";

export function WorkspaceRemovalMenu({
  workspace,
  onRemove,
  children,
}: {
  children: ReactNode;
  workspace: WorkspaceView;
  onRemove: () => void;
}) {
  const { t } = useI18n();
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuAnchor, setMenuAnchor] = useState<ContextMenuAnchor | null>(null);
  const [confirming, setConfirming] = useState(false);
  const cancel = useRef<HTMLButtonElement>(null);
  const trigger = useRef<HTMLDivElement>(null);
  const removeItem = useRef<HTMLElement>(null);
  const keyboardOpen = useRef(false);
  return (
    <>
      <div
        ref={trigger}
        className="task-project-context focus-ring"
        role="group"
        tabIndex={0}
        aria-label={t("workspace.actions", { title: workspace.displayName })}
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        onContextMenu={(event) => {
          event.preventDefault();
          keyboardOpen.current = false;
          setMenuAnchor(
            createContextMenuAnchor(
              event.currentTarget,
              event.clientX,
              event.clientY,
            ),
          );
          setMenuOpen(true);
        }}
        onKeyDown={(event) => {
          if (
            event.key !== "ContextMenu" &&
            !(event.shiftKey && event.key === "F10")
          )
            return;
          event.preventDefault();
          keyboardOpen.current = true;
          setMenuAnchor(event.currentTarget);
          setMenuOpen(true);
        }}
      >
        {children}
      </div>
      <Menu.Root
        open={menuOpen}
        onOpenChange={setMenuOpen}
        onOpenChangeComplete={(open) => {
          if (open && keyboardOpen.current) removeItem.current?.focus();
        }}
      >
        <Menu.Portal>
          <Menu.Positioner
            anchor={menuAnchor}
            positionMethod="fixed"
            sticky
            side="bottom"
            align="start"
            sideOffset={keyboardOpen.current ? 2 : 0}
            alignOffset={0}
            arrowPadding={0}
            collisionPadding={8}
          >
            <Menu.Popup
              className="task-menu-popover"
              finalFocus={() =>
                confirming ? false : (trigger.current ?? false)
              }
            >
              <Menu.Item ref={removeItem} onClick={() => setConfirming(true)}>
                <Icon name="folder-minus" />
                {t("workspace.remove")}
              </Menu.Item>
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
      <AlertDialog.Root open={confirming} onOpenChange={setConfirming}>
        <AlertDialog.Portal>
          <AlertDialog.Backdrop />
          <AlertDialog.Popup
            initialFocus={() => cancel.current ?? false}
            finalFocus={() =>
              trigger.current?.isConnected
                ? trigger.current
                : document.querySelector<HTMLButtonElement>(
                    ".sidebar-capability",
                  )
            }
          >
            <AlertDialog.Title>
              {t("workspace.remove_title", { title: workspace.displayName })}
            </AlertDialog.Title>
            <AlertDialog.Description>
              {t("workspace.remove_body")}
            </AlertDialog.Description>
            <div className="delete-confirmation-actions">
              <Button
                ref={cancel}
                variant="secondary"
                onClick={() => setConfirming(false)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                variant="primary"
                onClick={() => {
                  onRemove();
                  setConfirming(false);
                }}
              >
                {t("workspace.remove")}
              </Button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </>
  );
}
