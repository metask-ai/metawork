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
import { Button } from "./ui/button.tsx";
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
  /** The delivery list can compare this file with the recorded delivery. */
  delivery?: { opensInBrowser: boolean; viewSource?: () => void };
  /**
   * Copies the image it is shown as, from what the interface already holds.
   * Null while there is none to copy, absent for anything but an image.
   */
  copyImage?: ((signal: AbortSignal) => Promise<FileMenuOutcome>) | null;
};

export type FileMenuAction =
  "open" | "reveal" | "reference" | "copy_path" | "save" | "check";

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

export type OpenFileMenu = (
  file: MenuFile,
  event: ContextMenuEvent,
  atTrigger?: boolean,
) => void;
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
  /** In-flight actions, one per file: another file's menu stays usable. */
  const active = useRef(new Map<string, AbortController>());
  const [menu, setMenu] = useState<{
    file: MenuFile;
    anchor: ContextMenuAnchor;
  } | null>(null);
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState<
    ReadonlyMap<string, { action: MenuAction; cancelling: boolean }>
  >(new Map());
  const [notice, setNotice] = useState<FileMenuOutcome>(null);

  useEffect(
    () => () => {
      for (const controller of active.current.values()) controller.abort();
      active.current.clear();
      setPending(new Map());
      setNotice(null);
      setOpen(false);
    },
    [resetKey, connected],
  );
  useEffect(() => setNotice(null), [noticeKey]);
  const openMenu = useCallback<OpenFileMenu>(
    (file, event, atTrigger = false) => {
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
      keyboardOpen.current = atTrigger || !("clientX" in event);
      setMenu({
        file,
        anchor:
          !atTrigger && "clientX" in event
            ? createContextMenuAnchor(element, event.clientX, event.clientY)
            : element,
      });
      setOpen(true);
    },
    [],
  );

  async function perform(file: MenuFile, action: MenuAction) {
    const path = file.displayPath;
    if (!handler || active.current.has(path)) return;
    const controller = new AbortController();
    active.current.set(path, controller);
    setPending((current) =>
      new Map(current).set(path, { action, cancelling: false }),
    );
    setNotice(null);
    // An image is copied within the click: the clipboard asks for that.
    const outcome = await (
      action === "copy_image"
        ? file.copyImage!(controller.signal)
        : handler.perform(file, action, controller.signal)
    ).catch((): FileMenuOutcome => ({ message: "outputs.state.failed" }));
    if (active.current.get(path) !== controller) return;
    active.current.delete(path);
    setPending((current) => {
      const next = new Map(current);
      next.delete(path);
      return next;
    });
    setNotice(outcome);
  }

  function cancel(path: string) {
    const controller = active.current.get(path);
    if (!controller) return;
    controller.abort();
    setPending((current) => {
      const entry = current.get(path);
      return entry
        ? new Map(current).set(path, { ...entry, cancelling: true })
        : current;
    });
  }

  function disabled(file: MenuFile, action: MenuAction): boolean {
    return (
      !handler?.connected ||
      pending.has(file.displayPath) ||
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
        aria-busy={pending.size > 0}
        data-menu-open={open || undefined}
        className={
          className ? `file-menu-scope ${className}` : "file-menu-scope"
        }
        tabIndex={-1}
      >
        {children}
        {/* A check can take a while and is asked for in order to see its
            answer, so it says it is under way; routine actions stay quiet. */}
        {[...pending].map(
          ([path, entry]) =>
            entry.action === "check" && (
              <div key={path} className="file-menu-status">
                <p role="status" aria-live="polite">
                  {t(
                    entry.cancelling
                      ? "outputs.cancelling"
                      : "outputs.checking",
                  )}
                </p>
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={entry.cancelling}
                  onClick={() => cancel(path)}
                >
                  {t("outputs.cancel")}
                </Button>
              </div>
            ),
        )}
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
                    {t(
                      action === "open" && menu.file.delivery?.opensInBrowser
                        ? "outputs.open_browser"
                        : label,
                    )}
                  </Menu.Item>
                ))}
              {menu?.file.delivery && (
                <>
                  <Menu.Separator />
                  {menu.file.delivery.viewSource && (
                    <Menu.Item
                      disabled={disabled(menu.file, "check")}
                      onClick={menu.file.delivery.viewSource}
                    >
                      <Icon name="skill-file" />
                      {t("outputs.view_source")}
                    </Menu.Item>
                  )}
                  <Menu.Item
                    disabled={disabled(menu.file, "check")}
                    onClick={() => void perform(menu.file, "check")}
                  >
                    <Icon name="check" />
                    {t("outputs.check")}
                  </Menu.Item>
                </>
              )}
              {menu && pending.has(menu.file.displayPath) && (
                <>
                  <Menu.Separator />
                  <Menu.Item
                    disabled={pending.get(menu.file.displayPath)!.cancelling}
                    onClick={() => cancel(menu.file.displayPath)}
                  >
                    <Icon name="close" />
                    {t(
                      pending.get(menu.file.displayPath)!.cancelling
                        ? "outputs.cancelling"
                        : "outputs.cancel",
                    )}
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
