type SnapshotJson =
  | null
  | boolean
  | number
  | string
  | SnapshotJson[]
  | { [key: string]: SnapshotJson };

export type SnapshotInvoke = <T>(
  command: string,
  payload: SnapshotJson,
) => Promise<T>;

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

const maxSnapshotBytes = 8 * 1024 * 1024;
const maxSnapshotChunkBytes = 256 * 1024;

function positiveInteger(value: number, name: string) {
  if (!Number.isSafeInteger(value) || value <= 0)
    throw new Error(`Invalid Workbench snapshot ${name}`);
  return value;
}

function decodeBase64(value: string) {
  let binary: string;
  try {
    binary = atob(value);
  } catch {
    throw new Error("Invalid Workbench snapshot chunk encoding");
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1)
    bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export async function fetchWorkbenchSnapshot<T>(
  invoke: SnapshotInvoke,
  beginCommand: string,
  chunkCommand: string,
): Promise<T> {
  const descriptor = await invoke<SnapshotDescriptor>(beginCommand, {});
  if (!/^[1-9][0-9]*$/.test(descriptor.snapshotId))
    throw new Error("Invalid Workbench snapshot identity");
  const totalBytes = positiveInteger(descriptor.bytes, "size");
  const chunkBytes = positiveInteger(descriptor.chunkBytes, "chunk size");
  if (totalBytes > maxSnapshotBytes || chunkBytes > maxSnapshotChunkBytes)
    throw new Error("Workbench snapshot exceeds the negotiated bounds");

  const assembled = new Uint8Array(totalBytes);
  for (let offset = 0; offset < totalBytes; offset += chunkBytes) {
    const chunk = await invoke<SnapshotChunk>(chunkCommand, {
      snapshotId: descriptor.snapshotId,
      offset: String(offset),
    });
    const expectedBytes = Math.min(chunkBytes, totalBytes - offset);
    if (
      chunk.snapshotId !== descriptor.snapshotId ||
      chunk.offset !== offset ||
      chunk.bytes !== expectedBytes
    )
      throw new Error("Workbench snapshot chunk identity mismatch");
    const decoded = decodeBase64(chunk.data);
    if (decoded.length !== expectedBytes)
      throw new Error("Workbench snapshot chunk length mismatch");
    assembled.set(decoded, offset);
  }

  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(assembled);
  } catch {
    throw new Error("Workbench snapshot is not valid UTF-8");
  }
  return JSON.parse(text) as T;
}
