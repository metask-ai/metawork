export const WORKBENCH_SCHEMA_VERSION = 1 as const;

export type ToolView = {
  id: string;
  name: string;
  input: string;
  progress: string;
  content: string;
  state: "running" | "completed" | "failed";
  isError: boolean;
  elapsedMs: string;
};

export type RunView = {
  id: string;
  phase:
    | "queued"
    | "running"
    | "waiting_ui"
    | "completed"
    | "stopped"
    | "cancelled"
    | "interrupted"
    | "failed";
  user: string;
  assistant: string;
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
    | "bridge_pipeline_failure"
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
      kind: "ask_question";
      questions: AskQuestion[];
    }
  | {
      requestId: string;
      runId: string;
      kind: "permission";
      tool: string;
      args: string;
    }
  | {
      requestId: string;
      runId: string;
      kind: "plan_approval";
      plan: string;
    }
  | {
      requestId: string;
      runId: string;
      kind: "custom";
      customKind: string;
      payload: string;
    };

export type SessionView = {
  id: string;
  workspaceRoot: string;
  state: "idle" | "queued" | "running" | "waiting_ui" | "closing" | "closed";
  closeFailed: boolean;
  activeRunId: string;
  outcome: RunView["outcome"];
  cause: RunView["cause"];
  runs: RunView[];
  pendingUi: PendingUi | null;
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
  | { kind: "answers"; answers: string[] }
  | {
      kind: "plan_approval";
      planApproval: "reject" | "approve_default";
    };
