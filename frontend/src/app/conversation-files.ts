import type {
  MessageIdentity,
  RunInputView,
  RunView,
  TaskView,
  WorkspaceView,
} from "../bridge/contracts.ts";
import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import { referencePlugin } from "../components/ai/markdown-file-links.ts";
import { runFileReferenceLinks } from "../workbench/run-file-references.ts";
import { resolveWorkspaceFileLink } from "../workbench/workspace-file-links.ts";
import { deriveAssistantOutputParts } from "../features/tasks/assistant-output.ts";
import { fileTargetShown } from "../features/tasks/reply-files.ts";
import {
  workspaceConversationFile,
  type ConversationFile,
} from "../features/composer/conversation-files.ts";

/// Whether a file a conversation offered may join the draft open now: the
/// draft is that Task's, it can take input, nothing changed in between, and a
/// Workspace file is still shown in it. A file of another Task never joins.
export function conversationFileReferable(
  file: ConversationFile,
  draft: {
    allowed: boolean;
    task: TaskView | null | undefined;
    workspaces: readonly WorkspaceView[];
    /** The draft and audience are the ones the file was offered to. */
    current: boolean;
    scope: string;
  },
): boolean {
  const source = file.source;
  const target =
    source.kind === "workspace_file" ? source.target : source.attachment;
  return (
    file.available &&
    draft.allowed &&
    draft.current &&
    !!draft.task &&
    draft.task.id === target.taskId &&
    draft.scope === "task:" + target.taskId &&
    (source.kind !== "workspace_file" ||
      fileTargetShown(draft.task, draft.workspaces, source.target))
  );
}

const replyParser = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkMath, { singleDollarTextMath: false });

type Mention = readonly ["reference" | "workspace", string];

/// What each reply of the Task last read mentions. Every snapshot delivers the
/// same replies again while the picker is open; a reply is parsed again only
/// when its text, or the names it can match, changed. Opening another Task
/// drops the rest, so this never holds more than one Task's replies.
let mentionTaskId: string | null = null;
const mentionRuns = new Map<
  string,
  { key: string; mentions: readonly Mention[] }
>();

export function replyMentions(
  taskId: string,
  run: RunView,
  aliases: ReadonlyMap<string, unknown>,
  localLinks: boolean,
): readonly Mention[] {
  if (mentionTaskId !== taskId) {
    mentionTaskId = taskId;
    mentionRuns.clear();
  }
  const contents = deriveAssistantOutputParts(run.id, run.output).flatMap(
    (part) =>
      part.content && (aliases.size || part.content.includes("]"))
        ? [part.content]
        : [],
  );
  const key = JSON.stringify([localLinks, [...aliases.keys()], contents]);
  const cached = mentionRuns.get(run.id);
  if (cached?.key === key) return cached.mentions;
  const mentions: Mention[] = [];
  const collect = referencePlugin(aliases, localLinks, (kind, value) =>
    mentions.push([kind, value]),
  )();
  for (const content of contents) collect(replyParser.parse(content));
  mentionRuns.set(run.id, { key, mentions });
  return mentions;
}

/// The files a Task's conversation offers for reference: what was uploaded,
/// delivered or linked in a reply. It reads Task replies for the Composer's
/// picker, so it is composed here rather than in either feature.
export function conversationFiles(
  task: TaskView,
  workspace?: WorkspaceView | null,
): ConversationFile[] {
  const files = new Map<string, ConversationFile>();
  function add(file: ConversationFile) {
    if (!files.has(file.key)) files.set(file.key, file);
  }
  function addInput(
    input: RunInputView,
    message: MessageIdentity,
    time: string | null,
  ) {
    if (input.kind !== "multimodal") return;
    input.attachments.forEach((file, index) => {
      if (file.redacted || file.referenced) return;
      const attachment = {
        kind: "messageAttachment" as const,
        taskId: task.id,
        message,
        index,
      };
      add({
        key: JSON.stringify(attachment),
        name: file.displayName,
        time,
        imageFormat:
          file.kind === "image" && file.media ? file.format : undefined,
        available: Boolean(
          file.canReference || (file.kind === "image" && file.media),
        ),
        source: { kind: "message_file", attachment },
      });
    });
  }
  for (const entry of [...task.inputSubmissions].reverse()) {
    if (entry.state === "waiting")
      addInput(
        entry.input,
        { kind: "submission", operationId: entry.submission.operationId },
        entry.submission.receivedAtUnixMs,
      );
  }
  for (const run of [...task.runs].reverse()) {
    for (const file of run.outputs)
      if (!file.redacted && file.displayPath)
        add(
          workspaceConversationFile(
            {
              kind: "output",
              taskId: task.id,
              runId: run.id,
              outputId: file.id,
            },
            file.displayPath,
            run.submittedAtUnixMs,
          ),
        );
    for (const file of run.fileReferences?.media ?? [])
      if (file.displayPath)
        add(
          workspaceConversationFile(
            {
              kind: "reference",
              taskId: task.id,
              runId: run.id,
              fileReferenceId: file.id,
            },
            file.displayPath,
            run.submittedAtUnixMs,
          ),
        );
    const aliases = runFileReferenceLinks(run);
    for (const [kind, value] of replyMentions(
      task.id,
      run,
      aliases,
      Boolean(workspace),
    )) {
      const path =
        kind === "workspace"
          ? resolveWorkspaceFileLink(value, workspace?.canonicalRoot ?? null)
          : null;
      if (path?.kind === "unavailable") continue;
      const ref = aliases.get(path?.path ?? value);
      if (ref) {
        add(
          workspaceConversationFile(
            {
              kind: "reference",
              taskId: task.id,
              runId: run.id,
              fileReferenceId: ref.id,
            },
            ref.displayPath,
            run.submittedAtUnixMs,
          ),
        );
      } else if (workspace && path?.kind === "path") {
        add(
          workspaceConversationFile(
            {
              kind: "workspace",
              taskId: task.id,
              workspaceId: workspace.id,
              workspaceEpoch: workspace.epoch,
              path: path.path,
            },
            path.path,
            run.submittedAtUnixMs,
          ),
        );
      }
    }
    const message: MessageIdentity = run.submission
      ? { kind: "submission", operationId: run.submission.operationId }
      : { kind: "run", runId: run.id };
    addInput(
      run.input,
      message,
      run.submission?.receivedAtUnixMs ?? run.submittedAtUnixMs,
    );
  }
  for (const file of task.conversationOutputs ?? [])
    if (!file.redacted && file.displayPath)
      add(
        workspaceConversationFile(
          {
            kind: "output",
            taskId: task.id,
            runId: file.runId,
            outputId: file.id,
          },
          file.displayPath,
        ),
      );
  return [...files.values()];
}
