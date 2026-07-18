export const WORKBENCH_SCHEMA_VERSION = 4 as const;

export type ToolView = {
  id: string;
  order: string;
  name: string;
  input: string;
  progress: string;
  content: string;
  state: "running" | "completed" | "failed";
  isError: boolean;
  elapsedMs: string;
  inputTruncated: boolean;
  progressTruncated: boolean;
  contentTruncated: boolean;
  redacted: boolean;
};

export type RunPhase =
  | "queued"
  | "running"
  | "waiting_ui"
  | "stopping"
  | "completed"
  | "stopped"
  | "cancelled"
  | "interrupted"
  | "failed";

export type NonTerminalRunPhase = Extract<
  RunPhase,
  "queued" | "running" | "waiting_ui" | "stopping"
>;

export type RunView = {
  id: string;
  phase: RunPhase;
  user: string;
  assistant: string;
  assistantRedacted: boolean;
  status: string;
  outcome:
    | "completed"
    | "stopped"
    | "cancelled"
    | "interrupted"
    | "failed"
    | "dependency_contract_failure"
    | null;
  cause:
    | "user_cancel"
    | "timeout"
    | "session_close"
    | "host_shutdown"
    | "event_pipeline_failure"
    | "queue_capacity_failure"
    | "ui_pipeline_failure"
    | "dependency_contract_failure"
    | null;
  usage: {
    input: string;
    output: string;
    cacheRead: string;
    cacheCreation: string;
  };
  tools: ToolView[];
};

export type AskOption = {
  label: string;
  description: string;
  preview: string;
};

export type AskQuestion = {
  question: string;
  header: string;
  multi: boolean;
  options: AskOption[];
};

export type PendingUi =
  | {
      requestId: string;
      runId: string;
      order: string;
      redacted: boolean;
      kind: "ask_question";
      questions: AskQuestion[];
    }
  | {
      requestId: string;
      runId: string;
      order: string;
      redacted: boolean;
      kind: "permission";
      tool: string;
      args: string;
    };

export type UiRecord = {
  requestId: string;
  runId: string;
  order: string;
  kind: "ask_question" | "permission";
  state:
    | "answered"
    | "allowed_once"
    | "allowed_always"
    | "denied"
    | "denied_session"
    | "cancelled";
  detail: string;
  itemCount: number;
  detailTruncated: boolean;
  redacted: boolean;
};

export type SessionView = {
  id: string;
  title: string;
  workspaceRoot: string;
  lifecycle: "open" | "closing" | "closed";
  continuationAvailable: boolean;
  archived: boolean;
  closeFailed: boolean;
  currentRunId: string;
  currentRunPhase: NonTerminalRunPhase | null;
  lastRunOutcome: RunView["outcome"];
  cause: RunView["cause"];
  runs: RunView[];
  pendingUi: PendingUi | null;
  uiHistory: UiRecord[];
};

export type WorkbenchSnapshot = {
  schemaVersion: typeof WORKBENCH_SCHEMA_VERSION;
  revision: string;
  sessions: SessionView[];
};

export type HostSignal = {
  sequence: number;
  automation: boolean;
  gate5Fixture: boolean;
};

export type WorkspaceChoice =
  | { selected: false }
  | { selected: true; workspaceRoot: string; grant: string };

export type UiResponsePayload =
  | { kind: "permission"; permission: "deny_once" | "allow_once" }
  | { kind: "answers"; answers: string[] };
