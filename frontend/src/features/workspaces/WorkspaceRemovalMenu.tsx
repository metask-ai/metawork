import {
  useRef,
  useState,
  type ReactNode,
  type MouseEvent,
  type KeyboardEvent,
} from "react";
import type {
  WorkspaceOpenResult,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import {
  createContextMenuAnchor,
  type ContextMenuAnchor,
} from "../../components/ui/context-menu-anchor.ts";
import { useI18n } from "../../i18n/context.ts";
import { useWorkspaceDirectoryOpen } from "./useWorkspaceDirectoryOpen.ts";
import { WorkspaceOpenFailureNotice } from "./WorkspaceOpenFailureNotice.tsx";

export function WorkspaceRemovalMenu({
  workspace,
  onOpen,
  openDisabled,
  onNewTask,
  onRemove,
  children,
}: {
  children: ReactNode;
  workspace: WorkspaceView;
  onOpen: () => Promise<WorkspaceOpenResult>;
  openDisabled: boolean;
  onNewTask: () => void;
  onRemove: () => Promise<boolean>;
}) {
  const { t } = useI18n();
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuAnchor, setMenuAnchor] = useState<ContextMenuAnchor | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [removeFailed, setRemoveFailed] = useState(false);
  const { cannotOpen, openDirectory, openFailure, dismissOpenFailure } =
    useWorkspaceDirectoryOpen(workspace, onOpen, openDisabled);
  const cancel = useRef<HTMLButtonElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const popup = useRef<HTMLDivElement>(null);
  const removeItem = useRef<HTMLElement>(null);
  const openItem = useRef<HTMLElement>(null);
  const keyboardOpen = useRef(false);
  function openMenu(
    event: MouseEvent<HTMLElement> | KeyboardEvent<HTMLElement>,
    anchorToElement = false,
  ) {
    const button =
      event.target instanceof Element ? event.target.closest("button") : null;
    if (!button) return;
    event.preventDefault();
    event.stopPropagation();
    trigger.current = button;
    keyboardOpen.current =
      !("clientX" in event) || (anchorToElement && event.detail === 0);
    setMenuAnchor(
      "clientX" in event && !anchorToElement
        ? createContextMenuAnchor(button, event.clientX, event.clientY)
        : button,
    );
    setMenuOpen(true);
  }
  function handleMenuKey(event: KeyboardEvent<HTMLElement>) {
    if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10"))
      openMenu(event);
  }
  async function removeProject() {
    if (removing || openDisabled) return;
    setRemoving(true);
    setRemoveFailed(false);
    try {
      if (await onRemove()) setConfirming(false);
      else setRemoveFailed(true);
    } catch {
      setRemoveFailed(true);
    } finally {
      setRemoving(false);
    }
  }
  return (
    <>
      <div
        className="task-project-context"
        data-menu-open={menuOpen}
        onContextMenu={openMenu}
        onKeyDown={handleMenuKey}
      >
        {children}
        <button
          type="button"
          className="icon-button task-list-action task-project-new-trigger focus-ring"
          aria-label={t("workspace.new_conversation_for", {
            title: workspace.displayName,
          })}
          title={t("workspace.new_conversation")}
          disabled={openDisabled || workspace.authorization !== "available"}
          onClick={onNewTask}
        >
          <Icon name="new-task" />
        </button>
        <button
          type="button"
          className="icon-button task-list-action task-project-menu-trigger focus-ring"
          aria-label={t("workspace.actions", { title: workspace.displayName })}
          title={t("workspace.actions", { title: workspace.displayName })}
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          onClick={(event) => openMenu(event, true)}
        >
          <Icon name="more" />
        </button>
      </div>
      {openFailure && (
        <WorkspaceOpenFailureNotice
          failure={openFailure}
          className="task-list-empty"
          onDismiss={() => {
            dismissOpenFailure();
            if (trigger.current?.isConnected) trigger.current.focus();
          }}
        />
      )}
      <Menu.Root
        open={menuOpen}
        onOpenChange={setMenuOpen}
        onOpenChangeComplete={(open) => {
          if (open && keyboardOpen.current)
            // Let the menu register its items before focusing one for keyboard navigation.
            window.requestAnimationFrame(() => {
              if (popup.current?.hasAttribute("data-open"))
                (cannotOpen ? removeItem : openItem).current?.focus();
            });
        }}
      >
        <Menu.Portal>
          <Menu.Positioner
            anchor={menuAnchor}
            positionMethod="fixed"
            sticky
            side="bottom"
            align="start"
            sideOffset={menuAnchor && !("contextElement" in menuAnchor) ? 2 : 0}
            alignOffset={0}
            arrowPadding={0}
            collisionPadding={8}
          >
            <Menu.Popup
              ref={popup}
              className="task-menu-popover"
              finalFocus={() =>
                confirming ? false : (trigger.current ?? false)
              }
            >
              <Menu.Item
                ref={openItem}
                disabled={cannotOpen}
                onClick={() => void openDirectory()}
              >
                <Icon name="folder-open" />
                {t("workspace.open")}
              </Menu.Item>
              <Menu.Item
                ref={removeItem}
                onClick={() => {
                  setRemoveFailed(false);
                  setConfirming(true);
                }}
              >
                <Icon name="folder-minus" />
                {t("workspace.remove")}
              </Menu.Item>
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
      <AlertDialog.Root
        open={confirming}
        onOpenChange={(open) => {
          if (!removing) setConfirming(open);
        }}
      >
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
            {removeFailed && <p role="alert">{t("workspace.remove_failed")}</p>}
            <div className="delete-confirmation-actions">
              <Button
                ref={cancel}
                variant="secondary"
                disabled={removing}
                onClick={() => setConfirming(false)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                variant="primary"
                disabled={removing || openDisabled}
                onClick={() => void removeProject()}
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
