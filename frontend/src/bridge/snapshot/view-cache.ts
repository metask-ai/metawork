// Connection-owned delivery cache. Only Host-confirmed versions can fill omitted blocks.
import {
  emptyViewVersions,
  viewBlockNames,
  type ViewBlockName,
  type ViewScope,
  type ViewVersions,
  type WorkbenchSnapshot,
} from "../contracts.ts";
import { decodeViewVersions } from "../decode-contracts.ts";
import {
  object,
  positiveU64WireId,
  arrayValue,
  enumValue,
} from "../wire-codec.ts";

type Entry = {
  key: string;
  version: string;
  value: unknown;
  bytes: number;
  decoded: Partial<WorkbenchSnapshot>;
};
const decodedFields: Record<
  ViewBlockName,
  readonly (keyof WorkbenchSnapshot)[]
> = {
  context: [
    "automaticWorkspaceRoot",
    "capabilities",
    "permissions",
    "account",
    "models",
    "newTaskAdmission",
    "skillCatalog",
  ],
  workspaces: ["workspaces"],
  taskIndex: ["taskIndex"],
  taskPage: ["taskPage", "tasks"],
  historyPage: ["historyPage"],
  management: ["skillManagement", "mcp", "scheduledTasks"],
  searchIndex: ["searchIndex"],
};
const maxCacheBytes = 64 * 1024 * 1024;
function key(name: ViewBlockName, scope: ViewScope) {
  switch (name) {
    case "taskPage":
      return `${scope.taskId}:${scope.runLimit}`;
    case "historyPage":
      return `${scope.taskId}:${scope.beforeRunId}:${scope.runLimit}`;
    case "management":
      return scope.management;
    case "searchIndex":
      return String(scope.search);
    default:
      return name;
  }
}
// Conservative retained-tree budget, independent of browser string representation.
function retainedBytes(value: unknown): number {
  if (typeof value === "string") return 32 + value.length * 6;
  if (value === null || typeof value !== "object") return 16;
  if (Array.isArray(value))
    return 32 + value.reduce((sum, item) => sum + 8 + retainedBytes(item), 0);
  return (
    32 +
    Object.entries(value).reduce(
      (sum, [name, item]) => sum + 64 + name.length * 6 + retainedBytes(item),
      0,
    )
  );
}

export class ViewCache {
  private epoch = "0";
  private generation = 0;
  private securityFloor = "0";
  private entries = new Map<ViewBlockName, Entry>();
  clear() {
    this.epoch = "0";
    this.securityFloor = "0";
    this.entries.clear();
    this.generation += 1;
  }
  observeSecurityEpoch(epoch: string) {
    if (BigInt(epoch) <= BigInt(this.securityFloor)) return;
    if (this.securityFloor !== "0") this.clear();
    this.securityFloor = epoch;
  }
  capture(scope: ViewScope) {
    const entries = new Map(
      [...this.entries].filter(
        ([name, entry]) => entry.key === key(name, scope),
      ),
    );
    const versions: ViewVersions = { ...emptyViewVersions };
    for (const [name, entry] of entries) versions[name] = entry.version;
    return {
      generation: this.generation,
      epoch: this.epoch,
      entries,
      known: { securityEpoch: this.epoch, versions },
    };
  }
  materialize(
    value: unknown,
    scope: ViewScope,
    captured: ReturnType<ViewCache["capture"]>,
  ) {
    if (captured.generation !== this.generation)
      throw new Error("Product view connection changed during read");
    const root = object(value, "$", [
      "revision",
      "securityEpoch",
      "historyEpoch",
      "scope",
      ...viewBlockNames,
      "blockVersions",
      "reusedBlocks",
      "receipts",
    ]);
    const epoch = positiveU64WireId(root.securityEpoch, "$.securityEpoch");
    if (BigInt(epoch) < BigInt(this.securityFloor))
      throw new Error("Product view security epoch was revoked");
    const versions = decodeViewVersions(root.blockVersions);
    const reused = arrayValue(
      root.reusedBlocks,
      "$.reusedBlocks",
      (item) => item,
    ).map((item) => enumValue(item, "$.reusedBlocks[]", viewBlockNames));
    if (new Set(reused).size !== reused.length)
      throw new Error("Duplicate reused Product block");
    const materialized: Record<string, unknown> = { ...root, reusedBlocks: [] };
    for (const name of reused) {
      const entry = captured.entries.get(name);
      if (
        epoch !== captured.epoch ||
        !entry ||
        entry.version !== versions[name] ||
        root[name] !== null
      )
        throw new Error("Unconfirmed Product view block reuse");
      materialized[name] = entry.value;
    }
    return {
      wire: materialized,
      versions,
      epoch,
      reused,
      install: (decoded: WorkbenchSnapshot) => {
        for (const name of reused)
          Object.assign(decoded, captured.entries.get(name)!.decoded);
        if (captured.generation !== this.generation)
          throw new Error("Product view connection changed during read");
        if (this.epoch !== epoch) this.entries.clear();
        this.epoch = epoch;
        this.securityFloor = epoch;
        for (const name of viewBlockNames) {
          const existing = this.entries.get(name);
          if (
            reused.includes(name) &&
            existing?.version === versions[name] &&
            existing.key === key(name, scope)
          )
            continue;
          const item = materialized[name];
          const bytes = retainedBytes(item) * 2 + 256;
          this.entries.delete(name);
          if (bytes > maxCacheBytes) continue;
          while (
            [...this.entries.values()].reduce(
              (sum, entry) => sum + entry.bytes,
              0,
            ) +
              bytes >
            maxCacheBytes
          )
            this.entries.delete(this.entries.keys().next().value!);
          this.entries.set(name, {
            key: key(name, scope),
            version: versions[name],
            value: item,
            bytes,
            decoded: Object.fromEntries(
              decodedFields[name].map((field) => [field, decoded[field]]),
            ),
          });
        }
      },
    };
  }
}
