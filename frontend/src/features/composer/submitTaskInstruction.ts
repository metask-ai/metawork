export type TaskSubmissionClient = {
  createSession: (workspaceGrant: string) => Promise<string>;
  run: (sessionId: string, instruction: string) => Promise<unknown>;
};

export type TaskSubmissionResult =
  | { kind: "started"; sessionId: string; created: boolean }
  | { kind: "create_failed"; error: unknown }
  | { kind: "run_failed"; sessionId: string; created: boolean; error: unknown };

export async function submitTaskInstruction({
  client,
  sessionId,
  workspaceGrant,
  instruction,
  onSessionCreated,
}: {
  client: TaskSubmissionClient;
  sessionId: string | null;
  workspaceGrant: string;
  instruction: string;
  onSessionCreated: (sessionId: string) => void;
}): Promise<TaskSubmissionResult> {
  let targetSessionId = sessionId;
  let created = false;
  if (!targetSessionId) {
    if (!workspaceGrant)
      return {
        kind: "create_failed",
        error: new Error("Workspace access is required"),
      };
    try {
      targetSessionId = await client.createSession(workspaceGrant);
    } catch (error) {
      return { kind: "create_failed", error };
    }
    created = true;
    onSessionCreated(targetSessionId);
  }

  try {
    await client.run(targetSessionId, instruction);
  } catch (error) {
    return {
      kind: "run_failed",
      sessionId: targetSessionId,
      created,
      error,
    };
  }
  return { kind: "started", sessionId: targetSessionId, created };
}
