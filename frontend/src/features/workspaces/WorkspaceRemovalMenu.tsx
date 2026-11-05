import {
  useRef,
  useState,
  type ReactNode,
  type MouseEvent,
  type KeyboardEvent,
} from "react";
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
  onOpen,
  openDisabled,
  onNewTask,
  onRemove,
  children,
}: {
  children: ReactNode;
  workspace: WorkspaceView;
  onOpen: () => Promise<{ opened: boolean }>;
  openDisabled: boolean;
  onNewTask: () => void;
  onRemove: () => void;
}) {
  const { t } = useI18n();
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuAnchor, setMenuAnchor] = useState<ContextMenuAnchor | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [openState, setOpenState] = useState<"idle" | "opening" | "failed">(
    "idle",
  );
  const cancel = useRef<HTMLButtonElement>(null);
  const trigger = useRef<HTMLElement>(null);
  const removeItem = useRef<HTMLElement>(null);
  const openItem = useRef<HTMLElement>(null);
  const keyboardOpen = useRef(false);
  const cannotOpen =
    openDisabled ||
    openState === "opening" ||
    workspace.redacted ||
    workspace.authorization !== "available";
  function openMenu(
    event: MouseEvent<HTMLElement> | KeyboardEvent<HTMLElement>,
    anchorToElement = false,
  ) {
    event.preventDefault();
    event.stopPropagation();
    trigger.current = event.currentTarget;
    keyboardOpen.current =
      !("clientX" in event) || (anchorToElement && event.detail === 0);
    setMenuAnchor(
      "clientX" in event && !anchorToElement
        ? createContextMenuAnchor(
            event.currentTarget,
            event.clientX,
            event.clientY,
          )
        : event.currentTarget,
    );
    setMenuOpen(true);
  }
  function handleMenuKey(event: KeyboardEvent<HTMLElement>) {
    if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10"))
      openMenu(event);
  }
  async function openDirectory() {
    if (cannotOpen) return;
    setOpenState("opening");
    try {
      setOpenState((await onOpen()).opened ? "idle" : "failed");
    } catch {
      setOpenState("failed");
    }
  }
  return (
    <>
      <div
        className="task-project-context focus-ring"
        role="group"
        tabIndex={0}
        aria-label={t("workspace.actions", { title: workspace.displayName })}
        aria-haspopup="menu"
        aria-expanded={menuOpen}
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
          onContextMenu={openMenu}
          onKeyDown={handleMenuKey}
        >
          <Icon name="more" />
        </button>
      </div>
      {openState === "failed" && (
        <p className="task-list-empty" role="alert">
          {t("workspace.open_failed")}
        </p>
      )}
      <Menu.Root
        open={menuOpen}
        onOpenChange={setMenuOpen}
        onOpenChangeComplete={(open) => {
          if (open && keyboardOpen.current)
            // Let the menu register its items before focusing one for keyboard navigation.
            window.requestAnimationFrame(() => {
              if (trigger.current?.getAttribute("aria-expanded") === "true")
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
            sideOffset={menuAnchor instanceof HTMLElement ? 2 : 0}
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
              <Menu.Item
                ref={openItem}
                disabled={cannotOpen}
                onClick={() => void openDirectory()}
              >
                <Icon name="folder-open" />
                {t("workspace.open")}
              </Menu.Item>
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
