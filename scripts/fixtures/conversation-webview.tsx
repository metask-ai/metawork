// Renderer fixture only: real components and browser layout, no fake Host claims.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import {
  TaskContent,
  createTaskReadingMemory,
} from "../../frontend/src/features/tasks/TaskContent.tsx";
import { I18nContext } from "../../frontend/src/i18n/context.ts";
import { translate } from "../../frontend/src/i18n/runtime.ts";

const canvas = document.createElement("canvas");
canvas.width = 320;
canvas.height = 240;
const pixels = canvas.getContext("2d")!;
pixels.fillStyle = "#2463eb";
pixels.fillRect(0, 0, canvas.width, canvas.height);
pixels.fillStyle = "white";
pixels.font = "20px sans-serif";
pixels.fillText("ORIGINAL IMAGE", 50, 125);
const imageSource = canvas.toDataURL("image/png");
const host = document.createElement("main");
const siblings = [...document.body.children] as HTMLElement[];
for (const sibling of siblings) sibling.hidden = true;
host.id = "conversation-fixture";
host.style.cssText =
  "position:fixed;inset:0;background:var(--ui-surface-canvas);z-index:99999;display:flex;flex-direction:column";
document.body.append(host);
const root = createRoot(host);
const memory = createTaskReadingMemory();
let loads = 0,
  valid = true;
const listeners = new Set<() => void>();
const image = {
  id: "fixture-image",
  mediaType: "image/png",
  width: 320,
  height: 240,
  securityEpoch: "1",
  get src() {
    return valid ? imageSource : "";
  },
  valid: () => valid,
  subscribe: (listener: () => void) => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  beginDecode: async () => () => {},
  dispose() {
    valid = false;
    for (const listener of listeners) listener();
  },
};
const loadFilePreview = async () => {
  loads++;
  return {
    state: "ready",
    content: "",
    truncated: false,
    redacted: false,
    image,
  };
};
const metadata = (operationId: string, order: string, anchorRunId = "9") => ({
  operationId,
  receivedAtUnixMs: null,
  anchorRunId,
  afterOutputCount: 1,
  presentationOrder: order,
});
const input = {
  id: "1",
  operationId: "blue",
  text: "MAKE IT BLUE",
  redacted: false,
  sequence: 1,
  adoptedTurn: null,
  order: null,
  state: "pending",
  afterOutputCount: 1,
  submission: metadata("blue", "2"),
};
const base = {
  id: "9",
  conversationCoverage: "included",
  phase: "running",
  execution: {
    generation: "7",
    protocol: "anthropic_messages",
    model: "fixture-model",
  },
  input: { kind: "text", text: "GENERATE ORIGINAL IMAGE", redacted: false },
  output: {
    commentary: [
      "ORIGINAL IMAGE\n\n" + "A stable selectable paragraph.\n\n".repeat(15),
    ],
    response: "",
    responseKind: null,
    provisional: "",
    redacted: false,
    provisionalRedacted: false,
  },
  activity: { kind: "writing_response" },
  submittedAtUnixMs: null,
  finishedAtUnixMs: null,
  elapsedMs: "12000",
  terminal: null,
  usage: { input: "12", output: "5", cacheRead: "0", cacheCreation: "0" },
  additionalInputs: [input],
  tools: [
    {
      id: "image-tool",
      order: "1",
      name: "GenerateImage",
      bash: null,
      presentation: null,
      errorDetail: null,
      input: "",
      progress: "",
      content: "",
      state: "completed",
      isError: false,
      elapsedMs: "12",
      inputTruncated: false,
      progressTruncated: false,
      contentTruncated: false,
      redacted: false,
      fileRefs: [
        {
          id: "picture",
          title: "",
          displayPath: "original.png",
          generatedImage: true,
          presentationAnchor: { afterOutputCount: 1, presentationOrder: "1" },
        },
      ],
    },
  ],
};
const terminal = {
  outcome: "completed",
  cause: null,
  diagnosticDisposition: "absent",
  recordingIncomplete: false,
  modelError: null,
};
const done = {
  ...base,
  phase: "completed",
  terminal,
  activity: null,
  output: {
    ...base.output,
    responseKind: "final",
    response: "ADJUSTING AFTER INTERJECTION",
  },
};
const next = {
  ...done,
  id: "10",
  input: { kind: "text", text: "CONTINUE AFTER DETAILS", redacted: false },
  submission: { ...metadata("continue", "3"), afterOutputCount: 2 },
  additionalInputs: [],
  tools: [],
  output: {
    ...done.output,
    commentary: [],
    response:
      "NEXT RUN ANSWER\n\n" +
      "Keep this paged conversation scrollable.\n\n".repeat(35),
  },
};
let revision = 0;
function render(stage: string) {
  const runs =
    stage === "paged"
      ? [next]
      : stage === "history"
        ? [done, next]
        : [
            stage === "terminal"
              ? done
              : stage === "later"
                ? {
                    ...base,
                    output: {
                      ...base.output,
                      provisional: "ADJUSTING AFTER INTERJECTION",
                    },
                  }
                : base,
          ];
  const task = {
    id: "3",
    recentOrder: "1",
    title: "Conversation fixture",
    workspaceId: "1",
    binding: {},
    mcpAuthority: { kind: "unavailable", selection: null },
    approvalMode: "manual",
    permissionReviewState: "idle",
    lifecycle: "open",
    deletionStatus: "idle",
    continuationAvailable: true,
    archived: false,
    currentRunId: runs.at(-1)!.id,
    currentRunPhase: runs.at(-1)!.phase,
    context: { pressure: null, lastAutoCompact: null },
    inputSubmissions: [],
    runs,
    compacts: [],
    pendingUi: null,
    uiHistory: [],
  };
  flushSync(() =>
    root.render(
      <I18nContext.Provider
        value={{
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        }}
      >
        <TaskContent
          task={task as never}
          memory={memory}
          revision={String(++revision)}
          snapshotReceivedAt={null}
          synchronized={stage !== "invalidated"}
          requestingStop={false}
          composerHasDraft={false}
          retryAvailable={false}
          responseDisabled={false}
          fileChangesEnabled={false}
          outputsEnabled={false}
          webLink={{ open() {} } as never}
          onPrepareRetry={() => {}}
          onPreviewFile={() => {}}
          loadFilePreview={loadFilePreview as never}
          onReviewFileChanges={() => {}}
          onRespond={() => {}}
          renderPendingUi={() => null}
        />
        <textarea aria-label="Fixture composer" />
      </I18nContext.Provider>,
    ),
  );
}
Object.assign(window, {
  conversationFixture: {
    render,
    loads: () => loads,
    invalidate: () => {
      image.dispose();
      render("invalidated");
    },
    dispose: () => {
      root.unmount();
      host.remove();
      for (const sibling of siblings) sibling.hidden = false;
    },
  },
});
render("initial");
