import {
  decodeSnapshotDescriptor,
  decodeSnapshotPreparing,
  maxSnapshotBytes,
  maxSnapshotPreparationSteps,
  maxSnapshotChunkBytes,
} from "../generated-wire.ts";
import { ViewCache } from "./view-cache.ts";
import { commands } from "../commands.ts";
import { RendererBridgeContractError } from "../contract-error.ts";
import {
  initialViewScope,
  cloneViewScope,
  sameViewScope,
  type ViewScope,
  type WorkbenchSnapshot,
} from "../contracts.ts";
import { decodeWorkbenchSnapshot } from "../decode-contracts.ts";

type SnapshotJson =
  | null
  | boolean
  | number
  | string
  | SnapshotJson[]
  | { [key: string]: SnapshotJson };

export type SnapshotInvoke = (
  command: string,
  payload: SnapshotJson,
) => Promise<unknown>;

type SnapshotChunk = {
  snapshotId: string;
  offset: number;
  bytes: number;
  data: string;
};

function invalidSnapshot(diagnostic: string): never {
  throw new RendererBridgeContractError("invalid_response", diagnostic);
}

function positiveInteger(value: unknown, name: string) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0)
    invalidSnapshot(`Invalid Workbench snapshot ${name}`);
  return value;
}

function nonNegativeInteger(value: unknown, name: string) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0)
    invalidSnapshot(`Invalid Workbench snapshot ${name}`);
  return value;
}

function descriptor(value: unknown) {
  try {
    return decodeSnapshotDescriptor(value, "$snapshotDescriptor");
  } catch (error) {
    invalidSnapshot(
      error instanceof Error ? error.message : "Invalid snapshot descriptor",
    );
  }
}

function chunk(value: unknown): SnapshotChunk {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    invalidSnapshot("Invalid Workbench snapshot chunk");
  const item = value as Record<string, unknown>;
  if (
    Object.keys(item).sort().join(",") !==
    ["snapshotId", "offset", "bytes", "data"].sort().join(",")
  )
    invalidSnapshot("Invalid Workbench snapshot chunk fields");
  if (typeof item.snapshotId !== "string" || typeof item.data !== "string")
    invalidSnapshot("Invalid Workbench snapshot chunk value");
  return {
    snapshotId: item.snapshotId,
    offset: nonNegativeInteger(item.offset, "chunk offset"),
    bytes: positiveInteger(item.bytes, "chunk byte count"),
    data: item.data,
  };
}

function decodeBase64(value: string) {
  let binary: string;
  try {
    binary = atob(value);
  } catch {
    invalidSnapshot("Invalid Workbench snapshot chunk encoding");
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1)
    bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export async function fetchWorkbenchSnapshot(
  invoke: SnapshotInvoke,
  scope: ViewScope = initialViewScope,
  cache: ViewCache = new ViewCache(),
): Promise<WorkbenchSnapshot> {
  const requested = cloneViewScope(scope);
  const captured = cache.capture(requested);
  let response = await invoke(commands.snapshot, {
    ...requested,
    known: captured.known,
  });
  let preparingId: string | null = null;
  let steps = 0;
  while (
    typeof response === "object" &&
    response !== null &&
    "phase" in response
  ) {
    let pending;
    try {
      pending = decodeSnapshotPreparing(response, "$snapshotPreparing");
    } catch {
      invalidSnapshot("Invalid Workbench snapshot preparation");
    }
    if (
      ++steps > maxSnapshotPreparationSteps ||
      (preparingId !== null && pending.snapshotId !== preparingId)
    )
      invalidSnapshot("Workbench snapshot preparation identity or step limit");
    preparingId = pending.snapshotId;
    response = await invoke(commands.snapshot, {
      preparingSnapshotId: preparingId,
    });
  }
  const current = descriptor(response);
  if (preparingId !== null && current.snapshotId !== preparingId)
    invalidSnapshot("Workbench snapshot preparation identity mismatch");
  if (
    current.bytes > maxSnapshotBytes ||
    current.chunkBytes > maxSnapshotChunkBytes
  )
    invalidSnapshot("Workbench snapshot exceeds the negotiated bounds");

  const assembled = new Uint8Array(current.bytes);
  for (let offset = 0; offset < current.bytes; offset += current.chunkBytes) {
    const next = chunk(
      await invoke(commands.snapshotChunk, {
        snapshotId: current.snapshotId,
        offset: String(offset),
      }),
    );
    const expectedBytes = Math.min(current.chunkBytes, current.bytes - offset);
    if (
      next.snapshotId !== current.snapshotId ||
      next.offset !== offset ||
      next.bytes !== expectedBytes
    )
      invalidSnapshot("Workbench snapshot chunk identity mismatch");
    const decoded = decodeBase64(next.data);
    if (decoded.length !== expectedBytes)
      invalidSnapshot("Workbench snapshot chunk length mismatch");
    assembled.set(decoded, offset);
  }

  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(assembled);
  } catch {
    invalidSnapshot("Workbench snapshot is not valid UTF-8");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    invalidSnapshot("Workbench snapshot is not valid JSON");
  }
  try {
    const candidate = cache.materialize(parsed, requested, captured);
    const next = decodeWorkbenchSnapshot(candidate.wire);
    if (!sameViewScope(next.scope, requested))
      invalidSnapshot("Product view scope mismatch");
    candidate.install(next);
    return next;
  } catch (error) {
    if (error instanceof RendererBridgeContractError) throw error;
    invalidSnapshot(error instanceof Error ? error.message : String(error));
  }
}
