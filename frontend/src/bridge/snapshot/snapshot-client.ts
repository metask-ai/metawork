import { commands } from "../commands.ts";
import { RendererBridgeContractError } from "../contract-error.ts";
import type { WorkbenchSnapshot } from "../contracts.ts";
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

type SnapshotDescriptor = {
  snapshotId: string;
  bytes: number;
  chunkBytes: number;
};

type SnapshotChunk = {
  snapshotId: string;
  offset: number;
  bytes: number;
  data: string;
};

const maxSnapshotBytes = 64 * 1024 * 1024;
const maxSnapshotChunkBytes = 256 * 1024;

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

function descriptor(value: unknown): SnapshotDescriptor {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    invalidSnapshot("Invalid Workbench snapshot descriptor");
  const item = value as Record<string, unknown>;
  if (
    Object.keys(item).sort().join(",") !==
    ["bytes", "chunkBytes", "snapshotId"].sort().join(",")
  )
    invalidSnapshot("Invalid Workbench snapshot descriptor fields");
  if (
    typeof item.snapshotId !== "string" ||
    !/^[1-9][0-9]*$/.test(item.snapshotId)
  )
    invalidSnapshot("Invalid Workbench snapshot identity");
  return {
    snapshotId: item.snapshotId,
    bytes: positiveInteger(item.bytes, "size"),
    chunkBytes: positiveInteger(item.chunkBytes, "chunk size"),
  };
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
): Promise<WorkbenchSnapshot> {
  const current = descriptor(await invoke(commands.snapshot, {}));
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
    return decodeWorkbenchSnapshot(parsed);
  } catch (error) {
    if (error instanceof RendererBridgeContractError) throw error;
    invalidSnapshot(error instanceof Error ? error.message : String(error));
  }
}
