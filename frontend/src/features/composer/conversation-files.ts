import type { FileTarget } from "../../bridge/contracts.ts";
import type { ReferenceSource } from "../../bridge/attachment-receive.ts";

export type ConversationFile = {
  key: string;
  name: string;
  path?: string;
  time: string | null;
  imageFormat?: string;
  available: boolean;
  source: ReferenceSource;
};

export function workspaceConversationFile(
  target: FileTarget,
  path: string,
  time: string | null = null,
): ConversationFile {
  return {
    key: "workspace:" + path,
    name: path.split(/[\\/]/).at(-1) || path,
    path,
    time,
    available: true,
    source: { kind: "workspace_file", target },
  };
}
