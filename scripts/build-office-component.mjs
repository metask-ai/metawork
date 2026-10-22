import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  createReadStream,
  createWriteStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { buildOfficeLauncher } from "./build-office-launcher.mjs";
import {
  windowsSigningConfiguration,
  windowsSignArguments,
  windowsVerifyArguments,
} from "./package-windows.mjs";
import { runChild } from "./run-child-process.mjs";
import { officeComponentSources } from "./office-component-sources.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cache = path.join(root, ".zig-cache/office-component-sources");
const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const [key, value] = process.argv.slice(index, index + 2);
  if (
    !["--python", "--output", "--signing"].includes(key) ||
    !value ||
    options.has(key)
  )
    throw new Error(
      "Usage: build-office-component.mjs --python <absolute-builder-python> --output <new-absolute-tar.gz> [--signing required|none]",
    );
  options.set(key, value);
}
if (process.platform !== "win32" || process.arch !== "x64")
  throw new Error("Office component producer currently requires Windows x64");
const python = options.get("--python");
const output = options.get("--output");
if (
  !python ||
  !output ||
  !path.isAbsolute(python) ||
  !path.isAbsolute(output) ||
  !output.endsWith(".tar.gz") ||
  existsSync(output)
)
  throw new Error(
    "Explicit builder Python and new absolute .tar.gz output are required",
  );
const signing = options.get("--signing") ?? "required";
if (!["required", "none"].includes(signing))
  throw new Error("Invalid signing mode");
const signingConfiguration = windowsSigningConfiguration({ signing });
const { sources, wheels } = officeComponentSources(root);
mkdirSync(cache, { recursive: true });

async function fileDigest(filename) {
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(filename)) digest.update(chunk);
  return digest.digest("hex");
}

async function fetchSource(source, name) {
  if (
    !/^[a-f0-9]{64}$/u.test(source.sha256) ||
    new URL(source.url).protocol !== "https:"
  )
    throw new Error(
      "Office dependency requires a fixed HTTPS source and SHA256",
    );
  const filename = path.join(cache, name);
  if (!existsSync(filename)) {
    const partial = `${filename}.${randomUUID()}.partial`;
    let complete = false;
    try {
      const response = await fetch(source.url, {
        signal: AbortSignal.timeout(180_000),
      });
      if (!response.ok || new URL(response.url).protocol !== "https:")
        throw new Error(`Office dependency download failed: ${name}`);
      let bytes = 0;
      await pipeline(
        Readable.fromWeb(response.body),
        new Transform({
          transform(chunk, encoding, callback) {
            bytes += chunk.length;
            callback(
              bytes > (source.bytes ?? 256 * 1024 * 1024)
                ? new Error(`Office dependency byte budget exceeded: ${name}`)
                : null,
              chunk,
            );
          },
        }),
        createWriteStream(partial, { flags: "wx" }),
      );
      if (
        (source.bytes !== undefined && bytes !== source.bytes) ||
        (await fileDigest(partial)) !== source.sha256
      )
        throw new Error(`Office dependency digest mismatch: ${name}`);
      renameSync(partial, filename);
      complete = true;
    } finally {
      if (!complete && existsSync(partial)) unlinkSync(partial);
    }
  }
  if (
    (source.bytes !== undefined && statSync(filename).size !== source.bytes) ||
    (await fileDigest(filename)) !== source.sha256
  )
    throw new Error(
      `Cached Office dependency is corrupt; remove it explicitly: ${filename}`,
    );
  return filename;
}

function run(command, args, label, env) {
  return runChild(command, args, { cwd: root, label, env, timeoutMs: null });
}
const msi = await fetchSource(
  sources.libreoffice,
  path.basename(new URL(sources.libreoffice.url).pathname),
);
const nodeZip = await fetchSource(
  sources.node,
  path.basename(new URL(sources.node.url).pathname),
);
const font = await fetchSource(sources.font, "NotoSansCJKsc-Regular.otf");
const fontLicense = await fetchSource(
  sources.fontLicense,
  "NotoSansCJK-OFL.txt",
);
await run(
  "powershell.exe",
  [
    "-NoProfile",
    "-NonInteractive",
    "-File",
    path.join(root, "scripts/verify-office-vendor.ps1"),
    "-FilePath",
    msi,
  ],
  "Office MSI signature",
);

const stage = path.join(
  root,
  ".zig-cache/office-components",
  `build-${randomUUID()}`,
);
mkdirSync(stage, { recursive: true });
console.log(`Preparing Office component: ${stage}`);
await run(
  "msiexec.exe",
  [
    "/a",
    msi,
    "/qn",
    "/norestart",
    `TARGETDIR=${path.join(stage, "engine")}`,
    "/l*v",
    `${stage}.msi.log`,
  ],
  "Office administrative extraction",
);
await run(
  python,
  [
    path.join(root, "scripts/prepare-office-payload.py"),
    "layout",
    stage,
    nodeZip,
    font,
    fontLicense,
  ],
  "Office private layout",
);
const wheelDirectory = path.join(cache, "wheels");
mkdirSync(wheelDirectory, { recursive: true });
let hashedRequirements = "";
for (const wheel of wheels.wheels) {
  const name = path.basename(new URL(wheel.url).pathname);
  if (!name.endsWith(".whl"))
    throw new Error("Office Python sources must be wheels");
  const downloaded = await fetchSource(wheel, `wheels/${name}`);
  if (path.dirname(downloaded) !== wheelDirectory)
    throw new Error("Invalid wheel cache path");
  hashedRequirements += `${wheel.name}==${wheel.version} --hash=sha256:${wheel.sha256}\n`;
}
const requirementsPath = path.join(
  stage,
  "sources/python-hashed-requirements.txt",
);
writeFileSync(requirementsPath, hashedRequirements);
const environment = {
  ...process.env,
  PATH: `${path.join(stage, "engine/program")}${path.delimiter}${process.env.PATH ?? ""}`,
  PIP_CACHE_DIR: path.join(cache, "pip-cache"),
  PYTHONDONTWRITEBYTECODE: "1",
};
await run(
  python,
  [
    "-m",
    "pip",
    "--python",
    path.join(stage, "python/bin/python.exe"),
    "install",
    "--disable-pip-version-check",
    "--no-deps",
    "--no-index",
    "--require-hashes",
    "--no-compile",
    "--only-binary=:all:",
    "--find-links",
    wheelDirectory,
    "--target",
    path.join(stage, "python-packages"),
    "-r",
    requirementsPath,
  ],
  "Office locked Python libraries",
  environment,
);

// npm's public dependency selector reads the installed, root-lock-verified
// graph. It includes each selected package's real transitive placement rather
// than copying the checkout's unrelated desktop and SDK dependencies.
const where = spawnSync("where.exe", ["npm.cmd"], {
  encoding: "utf8",
  windowsHide: true,
});
if (where.status !== 0)
  throw new Error("npm is required by the component producer");
const npm = path.join(
  path.dirname(where.stdout.trim().split(/\r?\n/u)[0]),
  "node_modules/npm/bin/npm-cli.js",
);
if (!existsSync(npm)) throw new Error("Cannot locate npm's public CLI");
const query = spawnSync(
  process.execPath,
  [npm, "query", "#docx, #pptxgenjs, #docx *, #pptxgenjs *"],
  {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    timeout: 30000,
    windowsHide: true,
  },
);
if (query.status !== 0)
  throw new Error("Cannot read the authoring dependency closure");
const lock = JSON.parse(
  readFileSync(path.join(root, "package-lock.json"), "utf8"),
);
const pins = JSON.parse(
  readFileSync(path.join(root, "package.json"), "utf8"),
).devDependencies;
const authoring = {
  name: "@metawork/office-authoring",
  version: "1.0.0",
  private: true,
  dependencies: { docx: pins.docx, pptxgenjs: pins.pptxgenjs },
};
const packages = {
  "": {
    name: authoring.name,
    version: authoring.version,
    dependencies: authoring.dependencies,
  },
};
for (const selected of JSON.parse(query.stdout)) {
  const entry = lock.packages[selected.location];
  if (
    !entry ||
    entry.version !== selected.version ||
    !entry.integrity ||
    !selected.location.startsWith("node_modules/")
  )
    throw new Error("Installed Office dependency disagrees with the root lock");
  const { dev, devOptional, ...production } = entry;
  packages[selected.location] = production;
}
const authoringDirectory = path.join(stage, "authoring");
mkdirSync(authoringDirectory);
writeFileSync(
  path.join(authoringDirectory, "package.json"),
  JSON.stringify(authoring, null, 2) + "\n",
);
writeFileSync(
  path.join(authoringDirectory, "package-lock.json"),
  JSON.stringify(
    {
      name: authoring.name,
      version: authoring.version,
      lockfileVersion: 3,
      requires: true,
      packages,
    },
    null,
    2,
  ) + "\n",
);
await run(
  process.execPath,
  [
    npm,
    "ci",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    "--prefix",
    authoringDirectory,
  ],
  "Office locked JavaScript libraries",
  { ...environment, npm_config_cache: path.join(cache, "npm-cache") },
);
const launcher = path.join(stage, "bin/office.exe");
await buildOfficeLauncher({ targetId: sources.target, outputPath: launcher });
const debugSymbols = path.join(stage, "bin/office.pdb");
if (existsSync(debugSymbols)) unlinkSync(debugSymbols);
if (signingConfiguration) {
  await run(
    signingConfiguration.signTool,
    windowsSignArguments(signingConfiguration, launcher),
    "Sign Office entry",
  );
  await run(
    signingConfiguration.signTool,
    windowsVerifyArguments(launcher),
    "Verify Office entry",
  );
}
for (const executable of [
  "node/node.exe",
  "python/bin/python.exe",
  "engine/program/soffice.com",
]) {
  await run(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-File",
      path.join(root, "scripts/verify-office-vendor.ps1"),
      "-FilePath",
      path.join(stage, executable),
    ],
    "Office vendor signature",
  );
}
writeFileSync(
  path.join(stage, "sources/build.json"),
  JSON.stringify({ schema: 1, signing }, null, 2) + "\n",
);
await run(
  launcher,
  ["selftest"],
  "Office isolated offline self-test",
  environment,
);
await run(
  python,
  [
    path.join(root, "scripts/prepare-office-payload.py"),
    "package",
    stage,
    output,
  ],
  "Office component archive",
);
await run(
  python,
  [path.join(root, "scripts/check-office-component-archive.py"), output],
  "Office archive manifest verification",
);
console.log(`Office component built (${signing} signing): ${output}`);
