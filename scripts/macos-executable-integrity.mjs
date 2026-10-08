import { createHash } from "node:crypto";

function reject(reason) {
  throw new Error(`invalid macOS executable: ${reason}`);
}

function loadCommands(bytes) {
  if (bytes.length < 32 || bytes.readUInt32LE(0) !== 0xfeedfacf)
    reject("expected a thin little-endian 64-bit Mach-O");
  const commandCount = bytes.readUInt32LE(16);
  const commandEnd = 32 + bytes.readUInt32LE(20);
  if (commandEnd > bytes.length) reject("truncated load commands");
  const commands = [];
  let cursor = 32;
  for (let i = 0; i < commandCount; i++) {
    if (cursor + 8 > commandEnd) reject("truncated load command");
    const command = bytes.readUInt32LE(cursor);
    const size = bytes.readUInt32LE(cursor + 4);
    if (size < 8 || size % 8 !== 0 || cursor + size > commandEnd)
      reject("invalid load command size");
    commands.push({ command, size, cursor });
    cursor += size;
  }
  if (cursor !== commandEnd) reject("load command count differs from size");
  return { commands, commandEnd };
}

export function macosExecutableMinimumSystemVersion(bytes) {
  const versions = loadCommands(bytes).commands.filter(
    ({ command }) => command === 0x32,
  );
  if (versions.length !== 1) reject("expected one LC_BUILD_VERSION");
  const { cursor, size } = versions[0];
  if (size < 24 || size !== 24 + bytes.readUInt32LE(cursor + 20) * 8)
    reject("invalid LC_BUILD_VERSION size");
  if (bytes.readUInt32LE(cursor + 8) !== 1)
    reject("LC_BUILD_VERSION platform is not macOS");
  const packed = bytes.readUInt32LE(cursor + 12);
  const major = packed >>> 16;
  const minor = (packed >>> 8) & 0xff;
  const patch = packed & 0xff;
  if (major === 0) reject("invalid minimum macOS version");
  return patch === 0 ? `${major}.${minor}` : `${major}.${minor}.${patch}`;
}

// Signing may change load commands and __LINKEDIT, but must preserve every
// file-backed section at its original address and offset.
export function macosExecutableSections(bytes) {
  const { commands, commandEnd } = loadCommands(bytes);
  const name = (offset) =>
    bytes
      .subarray(offset, offset + 16)
      .toString("utf8")
      .split("\0")[0];
  const sections = [];
  for (const { command, size, cursor } of commands) {
    if (command === 0x19) {
      if (size < 72) reject("truncated segment");
      const sectionCount = bytes.readUInt32LE(cursor + 64);
      if (72 + sectionCount * 80 !== size) reject("invalid segment sections");
      for (let j = 0; j < sectionCount; j++) {
        const section = cursor + 72 + j * 80;
        const type = bytes.readUInt32LE(section + 64) & 0xff;
        if ([1, 0xc, 0x12].includes(type)) continue; // zero-fill sections
        const length = bytes.readBigUInt64LE(section + 40);
        if (length === 0n) continue;
        const offset = bytes.readUInt32LE(section + 48);
        const identity = `${name(section + 16)},${name(section)}`;
        if (offset < commandEnd) reject(`${identity} overlaps load commands`);
        if (BigInt(offset) + length > BigInt(bytes.length))
          reject(`${identity} exceeds file size`);
        sections.push({
          identity,
          address: bytes.readBigUInt64LE(section + 32).toString(),
          offset,
          length: length.toString(),
          digest: createHash("sha256")
            .update(bytes.subarray(offset, offset + Number(length)))
            .digest("hex"),
        });
      }
    }
  }
  if (!sections.some(({ identity }) => identity === "__TEXT,__text"))
    reject("missing executable text section");
  return sections;
}

export function verifyMacosExecutableSections(expected, bytes) {
  const actual = macosExecutableSections(bytes);
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error("macOS packaging or signing changed executable sections");
}
