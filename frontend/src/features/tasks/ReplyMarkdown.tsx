import type { ComponentProps } from "react";
import { Markdown, type MarkdownReference } from "../../components/ai/index.ts";
import { useOpenFileMenu, type MenuFile } from "../../components/FileMenu.tsx";

/** A file the text of a reply links to. */
export type ReplyReference = Omit<MarkdownReference, "onMenu"> & {
  file: MenuFile;
};
export type ReplyLocalLinks = (
  destination: string,
) => ReplyReference | { unavailable: string };

/** The text of a reply, whose file links open the menu of their file. */
export function ReplyMarkdown({
  references,
  localLinks,
  ...props
}: Omit<ComponentProps<typeof Markdown>, "references" | "localLinks"> & {
  references?: ReadonlyMap<string, ReplyReference>;
  localLinks?: ReplyLocalLinks;
}) {
  const openMenu = useOpenFileMenu();
  const withMenu = ({ file, ...reference }: ReplyReference) => ({
    ...reference,
    onMenu: openMenu
      ? (event: Parameters<typeof openMenu>[1]) => openMenu(file, event)
      : undefined,
  });
  return (
    <Markdown
      {...props}
      references={
        references &&
        new Map(
          [...references].map(([text, reference]) => [
            text,
            withMenu(reference),
          ]),
        )
      }
      localLinks={
        localLinks &&
        ((destination) => {
          const link = localLinks(destination);
          return "unavailable" in link ? link : withMenu(link);
        })
      }
    />
  );
}
