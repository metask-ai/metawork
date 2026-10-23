import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const normalize = (name) => name.toLowerCase().replace(/[_.-]+/gu, "-");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function officeComponentSources(root) {
  const sources = JSON.parse(
    readFileSync(
      path.join(root, "build_support/office-runtime.windows-x64.sources.json"),
      "utf8",
    ),
  );
  const wheels = JSON.parse(
    readFileSync(
      path.join(root, "build_support/office-python.windows-x64.lock.json"),
      "utf8",
    ),
  );
  const requirements = readFileSync(
    path.join(root, "scripts/office-requirements.txt"),
  );
  if (
    sources.schema !== 1 ||
    sources.target !== "x86_64-windows-msvc" ||
    wheels.schema !== 1 ||
    wheels.target !== sources.target ||
    wheels.python !== "3.13" ||
    wheels.requirementsSha256 !== digest(requirements)
  )
    throw new Error(
      "Office producer source locks do not match the current target and requirements",
    );
  const expected = new Map(
    requirements
      .toString("utf8")
      .split(/\r?\n/u)
      .filter(Boolean)
      .map((line) => {
        const match = /^([\w-]+)==([^\s]+)$/u.exec(line);
        if (!match)
          throw new Error("Office producer requirements must be fully pinned");
        return [normalize(match[1]), match[2]];
      }),
  );
  const selected = new Set();
  for (const wheel of wheels.wheels) {
    const name = normalize(wheel.name);
    if (
      selected.has(name) ||
      expected.get(name) !== wheel.version ||
      !new URL(wheel.url).pathname.endsWith(".whl")
    )
      throw new Error(
        "Office wheel lock has a missing, duplicate or different requirement",
      );
    selected.add(name);
  }
  if (selected.size !== expected.size)
    throw new Error(
      "Office wheel lock does not cover every pinned requirement",
    );
  const excluded = sources.libreoffice.excludedFileIds;
  if (
    !Array.isArray(excluded) ||
    excluded.length > 32 ||
    new Set(excluded.map((name) => name.toLowerCase())).size !==
      excluded.length ||
    excluded.some((name) => !/^[A-Za-z0-9_.-]+$/u.test(name))
  )
    throw new Error(
      "Office MSI source exclusions must be explicit bounded file identities",
    );
  for (const item of [
    ...Object.values(sources).filter((value) => typeof value === "object"),
    ...wheels.wheels,
  ]) {
    if (
      !/^[a-f0-9]{64}$/u.test(item.sha256) ||
      new URL(item.url).protocol !== "https:" ||
      (item.bytes !== undefined &&
        (!Number.isSafeInteger(item.bytes) ||
          item.bytes <= 0 ||
          item.bytes > 512 * 1024 * 1024))
    )
      throw new Error(
        "Office dependency needs a fixed HTTPS source, digest and bounded size",
      );
  }
  return { sources, wheels };
}

// Producer and public-source qualification must select the same transitive
// package placements from the canonical root lock, not a second dependency list.
export function officeAuthoringLock(root, selected) {
  const lock = JSON.parse(
    readFileSync(path.join(root, "package-lock.json"), "utf8"),
  );
  const pins = JSON.parse(
    readFileSync(path.join(root, "package.json"), "utf8"),
  ).devDependencies;
  const manifest = {
    name: "@metawork/office-authoring",
    version: "1.0.0",
    private: true,
    dependencies: { docx: pins.docx, pptxgenjs: pins.pptxgenjs },
  };
  const packages = {
    "": {
      name: manifest.name,
      version: manifest.version,
      dependencies: manifest.dependencies,
    },
  };
  for (const item of [...selected].sort((a, b) =>
    a.location.localeCompare(b.location, "en"),
  )) {
    const entry = lock.packages[item.location];
    if (
      !entry ||
      entry.version !== item.version ||
      !entry.integrity ||
      !/^node_modules\/(?:@[^/]+\/)?[^/]+(?:\/node_modules\/(?:@[^/]+\/)?[^/]+)*$/u.test(
        item.location,
      ) ||
      Object.hasOwn(packages, item.location)
    )
      throw new Error(
        "Installed Office dependency disagrees with the root lock",
      );
    const { dev, devOptional, ...production } = entry;
    packages[item.location] = production;
  }
  for (const [name, version] of Object.entries(manifest.dependencies))
    if (packages[`node_modules/${name}`]?.version !== version)
      throw new Error("Office authoring closure omits a required root package");
  return {
    manifest,
    lock: {
      name: manifest.name,
      version: manifest.version,
      lockfileVersion: 3,
      requires: true,
      packages,
    },
  };
}

export function queryOfficeAuthoring(root) {
  if (process.platform !== "win32")
    throw new Error(
      "Office producer source selection currently requires Windows",
    );
  const where = spawnSync("where.exe", ["npm.cmd"], {
    encoding: "utf8",
    windowsHide: true,
    timeout: 30000,
  });
  if (where.status !== 0)
    throw new Error("npm is required by the Office producer");
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
    throw new Error("Cannot read the Office authoring dependency closure");
  return { npm, ...officeAuthoringLock(root, JSON.parse(query.stdout)) };
}

export function officePublicDownloads(root, authoring) {
  const { sources, wheels } = officeComponentSources(root);
  const downloads = [
    ...Object.entries(sources)
      .filter(([, value]) => value && typeof value === "object")
      .map(([name, value]) => ({
        name,
        url: value.url,
        algorithm: "sha256",
        digest: value.sha256,
        bytes: value.bytes ?? null,
      })),
    ...wheels.wheels.map((wheel) => ({
      name: `python:${wheel.name}`,
      url: wheel.url,
      algorithm: "sha256",
      digest: wheel.sha256,
      bytes: null,
    })),
  ];
  for (const [location, entry] of Object.entries(authoring.lock.packages)) {
    if (!location) continue;
    const url = new URL(entry.resolved);
    const match = /^sha512-([A-Za-z0-9+/]{86}==)$/u.exec(entry.integrity);
    if (
      url.protocol !== "https:" ||
      url.hostname !== "registry.npmjs.org" ||
      url.username ||
      url.password ||
      url.port ||
      url.search ||
      url.hash ||
      !url.pathname.endsWith(".tgz") ||
      !match ||
      entry.hasInstallScript
    )
      throw new Error(
        "Office public JavaScript source needs a fixed registry tarball and SHA512 without install scripts",
      );
    downloads.push({
      name: `javascript:${location}`,
      url: entry.resolved,
      algorithm: "sha512",
      digest: Buffer.from(match[1], "base64").toString("hex"),
      bytes: null,
    });
  }
  if (downloads.length > 64)
    throw new Error(
      "Office public source count exceeds its qualification budget",
    );
  return downloads;
}

// Generated producer/bootstrap input, never a remote dependency resolver or a
// second list of package versions. Locations are the root lock's placements.
export function officeDependencyRecipe(root, authoring) {
  const { sources, wheels } = officeComponentSources(root);
  const downloads = officePublicDownloads(root, authoring);
  return {
    schema: 1,
    target: sources.target,
    archiveHelperSha256: digest(
      readFileSync(path.join(root, "src/product/control/resources/archive.py")),
    ),
    python: wheels.wheels.map((wheel) => ({
      name: wheel.name,
      version: wheel.version,
      source: `wheels/${path.basename(new URL(wheel.url).pathname)}`,
      algorithm: "sha256",
      digest: wheel.sha256,
    })),
    javascript: downloads
      .filter((item) => item.name.startsWith("javascript:"))
      .map((item) => {
        const location = item.name.slice("javascript:".length);
        const entry = authoring.lock.packages[location];
        return {
          name:
            entry.name ??
            location.slice(
              location.lastIndexOf("node_modules/") + "node_modules/".length,
            ),
          version: entry.version,
          location,
          source: `npm-archives/${item.digest}.tgz`,
          algorithm: item.algorithm,
          digest: item.digest,
        };
      }),
    authoring: { manifest: authoring.manifest, lock: authoring.lock },
  };
}
