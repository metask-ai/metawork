import type { WorkspaceChoice } from "../bridge/contracts.ts";
import { changed, demo } from "./state.ts";

type PickerRequest = { id: number };
let sequence = 0;
let pending: {
  request: PickerRequest;
  promise: Promise<WorkspaceChoice>;
  resolve: (choice: WorkspaceChoice) => void;
} | null = null;
const subscribers = new Set<() => void>();

export function subscribeWorkspacePicker(subscriber: () => void) {
  subscribers.add(subscriber);
  return () => {
    subscribers.delete(subscriber);
  };
}

export const getWorkspacePickerRequest = () => pending?.request ?? null;

export function requestDemoWorkspace(): Promise<WorkspaceChoice> {
  if (pending) return pending.promise;
  let resolve!: (choice: WorkspaceChoice) => void;
  const promise = new Promise<WorkspaceChoice>((complete) => {
    resolve = complete;
  });
  pending = { request: { id: ++sequence }, promise, resolve };
  subscribers.forEach((subscriber) => subscriber());
  return promise;
}

function finish(choice: WorkspaceChoice) {
  if (!pending) return false;
  const { resolve } = pending;
  pending = null;
  subscribers.forEach((subscriber) => subscriber());
  resolve(choice);
  return true;
}

export function cancelDemoWorkspace() {
  return finish({ selected: false });
}

export function selectDemoWorkspace(workspaceId: string) {
  const workspace = demo.workspaces.find((item) => item.id === workspaceId);
  if (
    !workspace ||
    workspace.kind !== "manual" ||
    workspace.authorization !== "available"
  )
    return false;
  return finish({ selected: true, workspaceId });
}

export function normalizeDemoWorkspaceName(value: string) {
  const name = value.trim().normalize("NFC");
  return name &&
    name.length <= 80 &&
    name !== "." &&
    name !== ".." &&
    !/[\/\\\u0000-\u001f\u007f]/u.test(name)
    ? name
    : null;
}

// Synthetic metadata only; this never creates a directory or grants file access.
export function addDemoWorkspace(value: string) {
  const name = normalizeDemoWorkspaceName(value);
  if (!pending || !name) return false;
  const canonicalRoot = `/Demo/${name}`;
  const existing = demo.workspaces.find(
    (item) => item.canonicalRoot === canonicalRoot,
  );
  if (existing) return selectDemoWorkspace(existing.id);
  const template = demo.workspaces.find((item) => item.kind === "manual");
  if (!template) return false;
  const id = String(
    demo.workspaces.reduce(
      (max, item) => (BigInt(item.id) > max ? BigInt(item.id) : max),
      0n,
    ) + 1n,
  );
  demo.workspaces.push({
    ...structuredClone(template),
    id,
    epoch: "1",
    kind: "manual",
    displayName: name,
    canonicalRoot,
    redacted: false,
    authorization: "available",
    lastRemovalFailure: null,
    recentOrder: id,
    signals: { running: 0, attention: 0, failedOrInterrupted: 0 },
    skillCatalog: structuredClone(demo.skillCatalog),
  });
  // Publish the authoritative demo snapshot before resolving the chooser.
  changed();
  return finish({ selected: true, workspaceId: id });
}
