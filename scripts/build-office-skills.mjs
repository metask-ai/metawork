// Deterministic, standard USTAR/gzip resources. No runtime component manifest.
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const root = fileURLToPath(new URL("..", import.meta.url));
const common = "src/product/skill/office_environment";
const sources = JSON.parse(
  readFileSync(path.join(root, "build_support/office-environment.json")),
);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const read = (name) => readFileSync(path.join(root, name));
const pythonId = hash(
  JSON.stringify(sources.python) +
    read(`${common}/requirements.txt`) +
    "layout-1",
);
const nodeId = hash(
  JSON.stringify(sources.node) +
    read(`${common}/package-lock.json`) +
    "layout-1",
);
const commands =
  Object.entries({
    PYTHON_ID: pythonId,
    PYTHON_URL: sources.python.url,
    PYTHON_SHA: sources.python.sha256,
    NODE_ID: nodeId,
    NODE_URL: sources.node.url,
    NODE_SHA: sources.node.sha256,
    NODE_FOLDER: `node-v${sources.node.version}-win-x64`,
  })
    .map(([key, value]) => {
      if (!/^[A-Za-z0-9:/._-]+$/.test(value))
        throw new Error("Unsafe fixed environment input");
      return `set "${key}=${value}"`;
    })
    .join("\r\n") + "\r\n";
const files = [];
function collect(directory, prefix) {
  for (const entry of readdirSync(path.join(root, directory), {
    withFileTypes: true,
  }).sort((a, b) => a.name.localeCompare(b.name, "en"))) {
    if (entry.name === "node_modules" || entry.name === "__pycache__")
      throw new Error("Unshippable Office resource");
    const source = `${directory}/${entry.name}`,
      name = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) collect(source, name);
    else if (entry.isFile()) files.push({ name, data: read(source) });
    else throw new Error("Office resource link");
  }
}
for (const skill of ["docx", "xlsx", "pptx"]) {
  collect(`src/product/skill/assets/${skill}`, skill);
  collect(common, `${skill}/environment`);
  files.push({
    name: `${skill}/environment/environment.cmd`,
    data: Buffer.from(commands),
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
const archive = gzipSync(
  Buffer.concat([...files.map(tarFile), Buffer.alloc(1024)]),
  { level: 9 },
);
const destination = path.join(root, "src/app/office-skills.tar.gz");
if (process.argv.includes("--check")) {
  if (!readFileSync(destination).equals(archive))
    throw new Error(
      "Office Skill archive is stale; run node scripts/build-office-skills.mjs",
    );
} else writeFileSync(destination, archive);
console.log(
  `Office Skills: ${files.length} files, ${archive.length} compressed bytes; Python ${pythonId}, Node ${nodeId}`,
);
