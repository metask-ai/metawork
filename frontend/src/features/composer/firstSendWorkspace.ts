export type FirstSendWorkspace =
  { kind: "ready"; grant: string } | { kind: "cancelled" };

export function workspaceGrantForRoot({
  draftActive,
  workspaceRoot,
  grantRoot,
  grant,
}: {
  draftActive: boolean;
  workspaceRoot: string | null;
  grantRoot: string | null;
  grant: string;
}) {
  return draftActive && workspaceRoot !== null && grantRoot === workspaceRoot
    ? grant
    : "";
}

export async function resolveFirstSendWorkspace({
  taskId,
  workspaceGrant,
  chooseWorkspace,
}: {
  taskId: string | null;
  workspaceGrant: string;
  chooseWorkspace: () => Promise<string | null>;
}): Promise<FirstSendWorkspace> {
  if (taskId !== null) return { kind: "ready", grant: workspaceGrant };
  if (workspaceGrant) return { kind: "ready", grant: workspaceGrant };
  const grant = await chooseWorkspace();
  return grant ? { kind: "ready", grant } : { kind: "cancelled" };
}
