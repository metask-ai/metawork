import { useEffect, useState } from "react";
import type { FileReferenceView, TaskView } from "../bridge/contracts.ts";
import { Icon } from "../components/ui/Icon.tsx";
import { useI18n } from "../i18n/context.ts";

// Scoped to synthetic files referenced by the current task. No filesystem access.
export function WorkspaceFiles({
  task,
  onPreview,
}: {
  task: TaskView | null;
  onPreview: (
    taskId: string,
    runId: string,
    reference: FileReferenceView,
    opener: HTMLButtonElement,
  ) => void;
}) {
  const { t } = useI18n();
  const [query, setQuery] = useState("");
  useEffect(() => setQuery(""), [task?.id]);
  const all =
    task?.runs.flatMap((run) =>
      run.tools
        .flatMap((tool) => tool.fileRefs)
        .map((reference) => ({ reference, runId: run.id })),
    ) ?? [];
  const unique = Array.from(
    new Map(all.map((file) => [file.reference.displayPath, file])).values(),
  );
  const files = unique.filter((file) =>
    file.reference.displayPath
      .toLocaleLowerCase()
      .includes(query.toLocaleLowerCase().trim()),
  );
  const links = Array.from(
    new Map(
      (task?.runs ?? []).flatMap((run) =>
        Array.from(
          (run.output.response ?? "").matchAll(
            /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
          ),
          (match) =>
            [match[2]!, { href: match[2]!, label: match[1]! }] as const,
        ),
      ),
    ).values(),
  ).filter((link) =>
    `${link.label} ${link.href}`
      .toLocaleLowerCase()
      .includes(query.toLocaleLowerCase().trim()),
  );
  return (
    <aside className="demo-workspace-files" aria-label={t("demo.files")}>
      <h3>
        <Icon name="workspace" />
        <span>{t("demo.files")}</span>
        <small>{unique.length}</small>
      </h3>
      <label className="demo-file-filter">
        <Icon name="search" />
        <input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t("demo.file_search")}
          aria-label={t("demo.file_search")}
        />
      </label>
      {files.length ? (
        <ul>
          {files.map((file) => (
            <li key={file.reference.displayPath}>
              <button
                type="button"
                className="focus-ring"
                title={file.reference.displayPath}
                onClick={(event) => {
                  if (task)
                    onPreview(
                      task.id,
                      file.runId,
                      file.reference,
                      event.currentTarget,
                    );
                }}
              >
                <Icon name="skill-file" />
                <span>{file.reference.displayPath}</span>
              </button>
            </li>
          ))}
        </ul>
      ) : (
        <p role="status">{t("demo.file_empty")}</p>
      )}
      {links.length > 0 && (
        <div className="demo-workspace-links">
          <h3>{t("demo.links")}</h3>
          <ul>
            {links.map((link) => (
              <li key={link.href}>
                <a href={link.href} target="_blank" rel="noreferrer">
                  <Icon name="external-link" />
                  <span>{link.label}</span>
                </a>
              </li>
            ))}
          </ul>
        </div>
      )}
    </aside>
  );
}
