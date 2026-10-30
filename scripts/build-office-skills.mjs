// Deterministic, standard USTAR/gzip resources. No runtime component manifest.
import { environment } from "./office-environment.mjs";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";

const root = fileURLToPath(new URL("..", import.meta.url));
const common = "src/product/skill/office_environment";
const sources = environment(root);
const check = process.argv.includes("--check");
if (
  !check &&
  (process.versions.node !== sources.generator.node ||
    process.versions.zlib !== sources.generator.zlib)
)
  throw Error(
    "Use the canonical Office resource generator Node/zlib from the manifest",
  );
const read = (name) => readFileSync(path.join(root, name));
const downloadSummary = [
  "| Native platform | Input target key | Python payload bytes | Node payload bytes |",
  "| --- | --- | ---: | ---: |",
  ...Object.entries(sources.targets).map(
    ([key, t]) =>
      `| ${key.startsWith("windows-") ? "Windows" : "macOS"} ${key.endsWith("aarch64") ? "arm64" : "x64"} | \`${key}\` | ${t.downloadTotals.python.totalBytes} | ${t.downloadTotals.node.totalBytes} |`,
  ),
].join("\n");
const executionTemplate = read(`${common}/EXECUTION.md`)
  .toString("utf8")
  .trim();
if (executionTemplate.split("{{OFFICE_DOWNLOAD_SUMMARY}}").length !== 2)
  throw Error(
    "Office execution instructions must include the download summary exactly once",
  );
const execution = executionTemplate.replace(
  "{{OFFICE_DOWNLOAD_SUMMARY}}",
  downloadSummary,
);
function constants(t) {
  return {
    OFFICE_NAMESPACE: sources.namespace,
    METAWORK_OFFICE_TARGET: t.target,
    PYTHON_ID: t.pythonId,
    PYTHON_URL: t.python.url,
    PYTHON_SHA: t.python.sha256,
    NODE_ID: t.nodeId,
    NODE_URL: t.node.url,
    NODE_SHA: t.node.sha256,
    NODE_FOLDER: t.node.archiveRoot,
    PYTHON_EXE: t.layout.pythonExecutable,
    NODE_EXE: t.layout.nodeExecutable,
  };
}
function safe(value) {
  if (!/^[A-Za-z0-9:/._%+-]+$/.test(value))
    throw Error("Unsafe fixed environment input");
  return value;
}
const commands = [
  '@if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" goto office_arm64',
  '@if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" goto office_arm64',
  '@if /i not "%PROCESSOR_ARCHITECTURE%"=="AMD64" exit /b 2',
  ...Object.entries(constants(sources.targets["windows-x86_64"])).map(
    ([k, v]) => `@set "${k}=${safe(v)}"`,
  ),
  "@exit /b 0",
  ":office_arm64",
  ...Object.entries(constants(sources.targets["windows-aarch64"])).map(
    ([k, v]) => `@set "${k}=${safe(v)}"`,
  ),
  "@exit /b 0",
  "",
].join("\r\n");
const shell = [
  'case "$(/usr/bin/uname -m)" in',
  ...[
    ["arm64", "macos-aarch64"],
    ["x86_64", "macos-x86_64"],
  ].flatMap(([arch, key]) => [
    `${arch})`,
    ...Object.entries(constants(sources.targets[key])).map(
      ([k, v]) => `${k}='${safe(v)}'`,
    ),
    ";;",
  ]),
  '*) echo "Unsupported Office target" >&2; exit 2 ;;',
  "esac",
  "export METAWORK_OFFICE_TARGET",
  "",
].join("\n");
const files = [];
function collect(directories, prefix) {
  const children = new Map();
  for (const directory of directories) {
    for (const entry of readdirSync(path.join(root, directory), {
      withFileTypes: true,
    })) {
      const sources = children.get(entry.name) ?? [];
      sources.push({ entry, source: `${directory}/${entry.name}` });
      children.set(entry.name, sources);
    }
  }
  for (const [leaf, sources] of [...children].sort(([a], [b]) =>
    a.localeCompare(b, "en"),
  )) {
    if (leaf === "node_modules" || leaf === "__pycache__")
      throw new Error("Unshippable Office resource");
    const name = `${prefix}/${leaf}`;
    if (sources.every(({ entry }) => entry.isDirectory()))
      collect(
        sources.map(({ source }) => source),
        name,
      );
    else if (sources.length !== 1)
      throw new Error(`Conflicting Office resource: ${name}`);
    else if (sources[0].entry.isFile()) {
      const { source } = sources[0];
      let data = read(source);
      if (
        leaf === "SKILL.md" &&
        source.startsWith("src/product/skill/assets/")
      ) {
        const text = data.toString("utf8");
        if (text.split("{{OFFICE_EXECUTION}}").length !== 2)
          throw Error(
            "Office Skill must include the shared execution instructions exactly once",
          );
        data = Buffer.from(text.replace("{{OFFICE_EXECUTION}}", execution));
      }
      if (source === `${common}/EXECUTION.md`)
        data = Buffer.from(execution + "\n");
      // Use Windows line endings for reliable cmd.exe label jumps across checkout settings.
      files.push({
        name,
        data: leaf.endsWith(".cmd")
          ? Buffer.from(data.toString("utf8").replace(/\r?\n/g, "\r\n"))
          : leaf.endsWith(".sh")
            ? Buffer.from(data.toString("utf8").replace(/\r\n/g, "\n"))
            : data,
      });
    } else throw new Error("Office resource link");
  }
}
for (const skill of ["docx", "xlsx", "pptx"]) {
  collect(
    [`src/product/skill/assets/${skill}`, "src/product/skill/office_resources"],
    skill,
  );
  collect([common], `${skill}/environment`);
  files.push({
    name: `${skill}/environment/environment.cmd`,
    data: Buffer.from(commands),
  });
  files.push({
    name: `${skill}/environment/environment.sh`,
    data: Buffer.from(shell),
  });
  files.push({
    name: `${skill}/environment/environment.json`,
    data: Buffer.from(JSON.stringify(sources)),
  });
  files.push({
    name: `${skill}/environment/office_archive.py`,
    data: read("src/product/control/resources/archive.py"),
  });
}
function tarFile({ name, data }) {
  const header = Buffer.alloc(512);
  let leaf = name,
    prefix = "";
  if (Buffer.byteLength(name) > 100) {
    const split = name.lastIndexOf("/");
    prefix = name.slice(0, split);
    leaf = name.slice(split + 1);
  }
  if (
    Buffer.byteLength(leaf) > 100 ||
    Buffer.byteLength(prefix) > 155 ||
    data.length > 1024 * 1024
  )
    throw new Error("Office resource budget");
  header.write(leaf, 0);
  header.write(prefix, 345);
  for (const [offset, size, value] of [
    [100, 8, 0o600],
    [108, 8, 0],
    [116, 8, 0],
    [124, 12, data.length],
    [136, 12, 0],
  ])
    header.write(value.toString(8).padStart(size - 1, "0") + "\0", offset);
  header.fill(32, 148, 156);
  header[156] = 48;
  header.write("ustar\0", 257);
  header.write("00", 263);
  const sum = header.reduce((a, b) => a + b, 0);
  header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148);
  return Buffer.concat([
    header,
    data,
    Buffer.alloc((512 - (data.length % 512)) % 512),
  ]);
}
if (
  files.length > 512 ||
  files.reduce((sum, f) => sum + f.data.length, 0) > 8 * 1024 * 1024
)
  throw new Error("Office resource budget");
const tar = Buffer.concat([...files.map(tarFile), Buffer.alloc(1024)]);
const destination = path.join(root, "src/app/office-skills.tar.gz");
const archive = check ? readFileSync(destination) : gzipSync(tar, { level: 9 });
if (check) {
  if (!gunzipSync(archive).equals(tar))
    throw new Error(
      "Office Skill archive is stale; run node scripts/build-office-skills.mjs",
    );
} else {
  // RFC 1952 unknown OS: remove the sole host-specific gzip header byte.
  archive[9] = 255;
  writeFileSync(destination, archive);
}
console.log(
  `Office Skills: ${files.length} files, ${archive.length} compressed bytes; ${Object.keys(sources.targets).length} targets`,
);
