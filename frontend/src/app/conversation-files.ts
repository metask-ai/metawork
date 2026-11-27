import type {
  MessageIdentity,
  RunInputView,
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
    const collect = referencePlugin(
      aliases,
      Boolean(workspace),
      (kind, value) => {
        const path =
          kind === "workspace"
            ? resolveWorkspaceFileLink(value, workspace?.canonicalRoot ?? null)
            : null;
        if (path?.kind === "unavailable") return;
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
      },
    )();
    for (const part of deriveAssistantOutputParts(run.id, run.output)) {
      if (part.content && (aliases.size || part.content.includes("]")))
        collect(replyParser.parse(part.content));
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
