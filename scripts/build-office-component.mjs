import { createHash, randomUUID } from "node:crypto";
import {
  createReadStream,
  createWriteStream,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmdirSync,
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
import {
  officeComponentSources,
  officeDependencyRecipe,
  queryOfficeAuthoring,
} from "./office-component-sources.mjs";
import { officeWorkflowInventory } from "./office-workflows.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function componentInventory(directory) {
  const entries = new Map();
  function visit(filename) {
    const status = lstatSync(filename, { bigint: true });
    entries.set(
      path.relative(directory, filename),
      `${status.mode}:${status.size}:${status.mtimeNs}`,
    );
    if (status.isDirectory()) {
      for (const name of readdirSync(filename))
        visit(path.join(filename, name));
    } else if (!status.isFile()) {
      throw new Error(
        "Office component self-test inventory contains a special entry",
      );
    }
  }
  visit(directory);
  return entries;
}
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
const workflows = officeWorkflowInventory(root);
if (
  workflows.tools.join(",") !== "office" ||
  workflows.nodePackages.map((entry) => entry.name).join(",") !==
    "docx,pptxgenjs"
)
  throw new Error(
    "Office workflows require an entry or authoring package not supplied by this producer",
  );
await run(
  python,
  ["-I", "-S", "-B", "-c", "import sys; assert sys.version_info >= (3, 9)"],
  "Office builder Python",
);
await run(
  python,
  [
    "-I",
    "-S",
    "-B",
    path.join(root, "scripts/check-office-package-bootstrap.py"),
  ],
  "Office offline dependency regressions",
);
mkdirSync(cache, { recursive: true });

async function fileDigest(filename, algorithm = "sha256") {
  const digest = createHash(algorithm);
  for await (const chunk of createReadStream(filename)) digest.update(chunk);
  return digest.digest("hex");
}

async function fetchSource(source, name) {
  const algorithm = source.algorithm ?? "sha256";
  const expectedDigest = source.digest ?? source.sha256;
  const url = new URL(source.url);
  if (
    !["sha256", "sha512"].includes(algorithm) ||
    !new RegExp(`^[a-f0-9]{${algorithm === "sha256" ? 64 : 128}}$`, "u").test(
      expectedDigest,
    ) ||
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  )
    throw new Error(
      "Office dependency requires a fixed HTTPS source and cryptographic digest",
    );
  const filename = path.join(cache, name);
  if (!existsSync(filename)) {
    const partial = `${filename}.${randomUUID()}.partial`;
    let complete = false;
    try {
      const response = await fetch(source.url, {
        redirect: "error",
        headers: { "Accept-Encoding": "identity" },
        signal: AbortSignal.timeout(180_000),
      });
      if (response.status !== 200 || response.redirected || !response.body)
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
        (source.bytes != null && bytes !== source.bytes) ||
        (await fileDigest(partial, algorithm)) !== expectedDigest
      )
        throw new Error(`Office dependency digest mismatch: ${name}`);
      renameSync(partial, filename);
      complete = true;
    } finally {
      if (!complete && existsSync(partial)) unlinkSync(partial);
    }
  }
  if (
    (source.bytes != null && statSync(filename).size !== source.bytes) ||
    (await fileDigest(filename, algorithm)) !== expectedDigest
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
const msiScratch = `${stage}.msi-scratch`;
mkdirSync(msiScratch);
await run(
  python,
  [
    "-I",
    "-S",
    "-B",
    "-X",
    "utf8",
    path.join(root, "src/app/office_bootstrap/msi.py"),
    msi,
    path.join(stage, "engine"),
    msiScratch,
    String(sources.libreoffice.bytes),
    sources.libreoffice.sha256,
    ...sources.libreoffice.excludedFileIds.flatMap((name) => [
      "--exclude",
      name,
    ]),
  ],
  "Office read-only MSI extraction",
);
rmdirSync(msiScratch); // empty only, after the isolated extractor has exited
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
for (const wheel of wheels.wheels) {
  const name = path.basename(new URL(wheel.url).pathname);
  if (!name.endsWith(".whl"))
    throw new Error("Office Python sources must be wheels");
  const downloaded = await fetchSource(wheel, `wheels/${name}`);
  if (path.dirname(downloaded) !== wheelDirectory)
    throw new Error("Invalid wheel cache path");
}
const authoring = queryOfficeAuthoring(root);
const dependencyRecipe = officeDependencyRecipe(root, authoring);
mkdirSync(path.join(cache, "npm-archives"), { recursive: true });
for (const item of dependencyRecipe.javascript) {
  const entry = authoring.lock.packages[item.location];
  await fetchSource({ ...item, url: entry.resolved }, item.source);
}
const dependencyRecipePath = path.join(
  stage,
  "sources/office-dependency-layout.json",
);
writeFileSync(
  dependencyRecipePath,
  JSON.stringify(dependencyRecipe, null, 2) + "\n",
);
await run(
  python,
  [
    "-I",
    "-S",
    "-B",
    "-X",
    "utf8",
    path.join(root, "src/app/office_bootstrap/packages.py"),
    dependencyRecipePath,
    cache,
    stage,
    "--archive-helper",
    path.join(root, "src/product/control/resources/archive.py"),
  ],
  "Office pinned offline Python/JavaScript libraries",
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
const immutableBefore = componentInventory(stage);
await run(launcher, ["selftest"], "Office isolated offline self-test", {
  ...process.env,
  PATH: `${path.join(stage, "engine/program")}${path.delimiter}${process.env.PATH ?? ""}`,
  PYTHONDONTWRITEBYTECODE: "1",
});
const immutableAfter = componentInventory(stage);
if (
  immutableBefore.size !== immutableAfter.size ||
  [...immutableBefore].some(
    ([name, identity]) => immutableAfter.get(name) !== identity,
  )
)
  throw new Error("Office self-test changed the immutable component directory");
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
