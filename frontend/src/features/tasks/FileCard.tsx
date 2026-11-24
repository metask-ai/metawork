import { FileTypeIcon } from "../../components/FileTypeIcon.tsx";
import {
  useFileMenuTrigger,
  type MenuFile,
} from "../../components/FileMenu.tsx";
import { useI18n } from "../../i18n/context.ts";

export function fileName(displayPath: string): string {
  return displayPath.split("/").at(-1) || displayPath;
}

/**
 * One file in a reply. With `onOpen` it is a button that previews the file.
 * Without it there is nothing to activate: it is not a disabled button, which
 * would read as unavailable and could not be reached, but a focusable group
 * whose menu still opens.
 */
export function FileCard({
  name,
  detail,
  menu,
  onOpen,
}: {
  name: string;
  /** The size, or why there is none, and what else there is to say. */
  detail: readonly string[];
  menu: MenuFile | null;
  onOpen?: (opener: HTMLButtonElement) => void;
}) {
  const { t } = useI18n();
  const trigger = useFileMenuTrigger(menu);
  const label = [name, ...detail].join(t("file_card.separator"));
  const body = (
    <>
      <FileTypeIcon name={name} />
      <span className="file-card-text">
        <span className="file-card-name">{name}</span>
        <span className="file-card-detail">{detail.join(" · ")}</span>
      </span>
    </>
  );
  return onOpen ? (
    <button
      type="button"
      className="file-card focus-ring"
      aria-label={t("file_preview.open", { path: label })}
      onClick={(event) => onOpen(event.currentTarget)}
      {...trigger}
    >
      {body}
    </button>
  ) : (
    <div
      role="group"
      tabIndex={0}
      className="file-card focus-ring"
      aria-label={label}
      {...trigger}
    >
      {body}
    </div>
  );
}
