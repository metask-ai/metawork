import { renderToStaticMarkup } from "react-dom/server";
import { I18nContext } from "../src/i18n/context.ts";
import { translate } from "../src/i18n/runtime.ts";
import { demo } from "../src/demo/state.ts";
import {
  TaskContent,
  createTaskReadingMemory,
} from "../src/features/tasks/TaskContent.tsx";

export function renderScenario(
  kind:
    | "completed"
    | "expanded"
    | "expanded-no-tools"
    | "basename-collision"
    | "failed"
    | "approval"
    | "streaming",
) {
  const task = structuredClone(demo.tasks[0]);
  const run = task.runs[0];
  run.output.commentary = ["PROCESS_NOTE_SENTINEL"];
  run.output.response = "RESULT_SENTINEL";
  run.output.responseKind = "final";
  const memory = createTaskReadingMemory();
  if (kind === "basename-collision") {
    run.tools[0].fileRefs = [
      {
        id: "1",
        title: "产品设计计划.md",
        displayPath: "other/产品设计计划.md",
      },
    ];
    run.fileChanges = null;
  }
  if (kind === "expanded-no-tools") run.tools = [];
  if (kind === "expanded" || kind === "expanded-no-tools")
    memory.processDisclosure.set(`${task.id}:${run.id}`, { expanded: true });
  if (kind === "failed") {
    run.phase = "failed";
    run.terminal = {
      outcome: "failed",
      cause: "provider_failure",
      diagnosticDisposition: "absent",
    };
  }
  if (kind === "approval") {
    run.phase = "waiting_ui";
    run.activity = { kind: "waiting_user" };
    run.terminal = null;
    task.pendingUi = {
      requestId: "1",
      runId: run.id,
      order: "1",
      redacted: false,
      kind: "confirmation",
      title: "PENDING_SENTINEL",
      body: "",
      choices: [],
    } as typeof task.pendingUi;
  }
  if (kind === "streaming") {
    run.phase = "running";
    run.activity = { kind: "writing_response" };
    run.terminal = null;
    run.output.responseKind = null;
    run.output.response = "";
    run.output.provisional = "STREAMING_SENTINEL";
  }
  return renderToStaticMarkup(
    <I18nContext.Provider
      value={{
        locale: "zh-CN",
        setLocale: () => {},
        t: (id, values) => translate("zh-CN", id, values),
      }}
    >
      <TaskContent
        task={task}
        memory={memory}
        snapshotReceivedAt={null}
        synchronized
        requestingStop={false}
        revision="1"
        composerHasDraft={false}
        retryAvailable
        responseDisabled={false}
        fileChangesEnabled
        outputsEnabled
        onOutputAction={async () => "ready"}
        onPrepareOutputEdit={() => "edit_prepared"}
        onPrepareRetry={() => {}}
        onPreviewFile={() => {}}
        onReviewFileChanges={() => {}}
        onRespond={() => {}}
        renderPendingUi={() => <aside>PENDING_SENTINEL</aside>}
        webLink={{ failedLabel: "", onOpen: async () => true }}
      />
    </I18nContext.Provider>,
  );
}
