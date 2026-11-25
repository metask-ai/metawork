import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useI18n, type MessageId } from "../i18n/context.ts";
import {
  contextMenuProps,
  createContextMenuAnchor,
  type ContextMenuAnchor,
  type ContextMenuEvent,
} from "./ui/context-menu-anchor.ts";
import { Icon } from "./ui/Icon.tsx";
import { Menu } from "./ui/menu.tsx";

/** The file a menu was opened on. Only the handler knows what `target` names. */
export type MenuFile = {
  target: unknown;
  /** What the interface already shows for it. */
  displayPath: string;
  /** False when nothing can be done with it: it is missing or out of reach. */
  available?: boolean;
  /** False when the Host said it does not open it. Nobody asked when absent. */
  openable?: boolean;
  /**
   * Copies the image it is shown as, from what the interface already holds.
   * Null while there is none to copy, absent for anything but an image.
   */
  copyImage?: ((signal: AbortSignal) => Promise<FileMenuOutcome>) | null;
};

export type FileMenuAction =
  "open" | "reveal" | "reference" | "copy_path" | "save";

/** A failure that needs attention, or null for a silent outcome. */
export type FileMenuOutcome = { message: MessageId } | null;

export type FileMenuHandler = {
  connected: boolean;
  canReference: boolean;
  perform: (
    file: MenuFile,
    action: FileMenuAction,
    signal: AbortSignal,
  ) => Promise<FileMenuOutcome>;
};

const FileMenuHandlerContext = createContext<FileMenuHandler | null>(null);
export const FileMenuProvider = FileMenuHandlerContext.Provider;

export type OpenFileMenu = (file: MenuFile, event: ContextMenuEvent) => void;
const OpenFileMenuContext = createContext<OpenFileMenu | null>(null);

type MenuAction = FileMenuAction | "copy_image";
const copyImage = {
  action: "copy_image",
  icon: "copy",
  label: "outputs.copy_image",
} as const;
const items = [
  { action: "open", icon: "external-link", label: "outputs.open" },
  { action: "reveal", icon: "folder-open", label: "outputs.reveal" },
  { action: "reference", icon: "edit", label: "outputs.edit" },
  { action: "copy_path", icon: "copy", label: "outputs.copy_path" },
  { action: "save", icon: "download", label: "outputs.save" },
] as const;

/** Opens the menu of a file in the nearest scope; null without one. */
export function useOpenFileMenu(): OpenFileMenu | null {
  return useContext(OpenFileMenuContext);
}

/** What an element needs to open the menu of its file. */
export function useFileMenuTrigger(file: MenuFile | null) {
  const openMenu = useOpenFileMenu();
  return contextMenuProps(
    openMenu && file && ((event) => openMenu(file, event)),
  );
}

/**
 * One region whose files share a menu and the line that reports on it. Opening
 * the menu asks nothing of the Host: what is greyed out follows from what the
 * interface already knows.
 */
export function FileMenuScope({
  className,
  resetKey = "",
  noticeKey = "",
  children,
}: {
  className?: string;
  /** A result belongs to what was asked; a change of this drops both. */
  resetKey?: string;
  /** What is said about a finished action is said until this changes. */
  noticeKey?: string;
  children: ReactNode;
}) {
  const { t } = useI18n();
  const handler = useContext(FileMenuHandlerContext);
  const connected = handler?.connected ?? false;
  const root = useRef<HTMLDivElement>(null);
  const popup = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLElement | null>(null);
  const keyboardOpen = useRef(false);
  const active = useRef<AbortController | null>(null);
  const [menu, setMenu] = useState<{
    file: MenuFile;
    anchor: ContextMenuAnchor;
  } | null>(null);
  const [open, setOpen] = useState(false);
  const [pendingPath, setPendingPath] = useState<string | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [notice, setNotice] = useState<FileMenuOutcome>(null);

  useEffect(
    () => () => {
      active.current?.abort();
      active.current = null;
      setPendingPath(null);
      setNotice(null);
      setOpen(false);
    },
    [resetKey, connected],
  );
  useEffect(() => setNotice(null), [noticeKey]);
  const openMenu = useCallback<OpenFileMenu>((file, event) => {
    event.preventDefault();
    event.stopPropagation();
    const element = event.currentTarget;
    // Focus returns to what held it, which may be inside the element: a
    // playing video keeps the focus of its own controls.
    trigger.current =
      document.activeElement instanceof HTMLElement &&
      element.contains(document.activeElement)
        ? document.activeElement
        : element;
    keyboardOpen.current = !("clientX" in event);
    setMenu({
      file,
      anchor:
        "clientX" in event
          ? createContextMenuAnchor(element, event.clientX, event.clientY)
          : element,
    });
    setOpen(true);
  }, []);

  async function perform(file: MenuFile, action: MenuAction) {
    if (!handler || active.current) return;
    const controller = new AbortController();
    active.current = controller;
    setPendingPath(file.displayPath);
    setCancelling(false);
    setNotice(null);
    // An image is copied within the click: the clipboard asks for that.
    const outcome = await (
      action === "copy_image"
        ? file.copyImage!(controller.signal)
        : handler.perform(file, action, controller.signal)
    ).catch((): FileMenuOutcome => ({ message: "outputs.state.failed" }));
    if (active.current !== controller) return;
    active.current = null;
    setPendingPath(null);
    setNotice(outcome);
  }

  function disabled(file: MenuFile, action: MenuAction): boolean {
    return (
      !handler?.connected ||
      pendingPath !== null ||
      file.available === false ||
      (action === "copy_image" && !file.copyImage) ||
      (action === "open" && file.openable === false) ||
      (action === "reference" && !handler.canReference)
    );
  }

  return (
    <OpenFileMenuContext.Provider value={handler ? openMenu : null}>
      <div
        ref={root}
        aria-busy={pendingPath !== null}
        className={
          className ? `file-menu-scope ${className}` : "file-menu-scope"
        }
        tabIndex={-1}
      >
        {children}
        {notice && (
          <div className="file-menu-status">
            <p role="status">{t(notice.message)}</p>
          </div>
        )}
      </div>
      <Menu.Root
        open={open}
        onOpenChange={setOpen}
        onOpenChangeComplete={(opened) => {
          if (opened && keyboardOpen.current)
            // Let the menu register its items before focusing one.
            window.requestAnimationFrame(() => {
              if (popup.current?.hasAttribute("data-open"))
                popup.current
                  .querySelector<HTMLElement>(
                    '[role="menuitem"]:not([aria-disabled="true"]):not([data-disabled])',
                  )
                  ?.focus();
            });
        }}
      >
        <Menu.Portal>
          <Menu.Positioner
            anchor={menu?.anchor}
            positionMethod="fixed"
            sticky
            side="bottom"
            align="start"
            sideOffset={menu && !("contextElement" in menu.anchor) ? 2 : 0}
            alignOffset={0}
            arrowPadding={0}
            collisionPadding={8}
          >
            <Menu.Popup
              ref={popup}
              className="file-menu"
              aria-label={t("file_menu.label")}
              finalFocus={() =>
                trigger.current?.isConnected ? trigger.current : root.current
              }
            >
              {menu &&
                [
                  ...(menu.file.copyImage === undefined ? [] : [copyImage]),
                  ...items,
                ].map(({ action, icon, label }) => (
                  <Menu.Item
                    key={action}
                    disabled={disabled(menu.file, action)}
                    onClick={() => void perform(menu.file, action)}
                  >
                    <Icon name={icon} />
                    {t(label)}
                  </Menu.Item>
                ))}
              {menu && pendingPath === menu.file.displayPath && (
                <>
                  <Menu.Separator />
                  <Menu.Item
                    disabled={cancelling}
                    onClick={() => {
                      if (!active.current) return;
                      active.current.abort();
                      setCancelling(true);
                    }}
                  >
                    <Icon name="close" />
                    {t(cancelling ? "outputs.cancelling" : "outputs.cancel")}
                  </Menu.Item>
                </>
              )}
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
    </OpenFileMenuContext.Provider>
  );
}
