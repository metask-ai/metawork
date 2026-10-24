// One target manifest and one identity algorithm for generated Office resources.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

export const targetKeys = [
  "windows-x86_64",
  "windows-aarch64",
  "macos-aarch64",
  "macos-x86_64",
];
const hash = (value) => createHash("sha256").update(value).digest("hex");
export function environment(root) {
  const source = JSON.parse(
    readFileSync(path.join(root, "build_support/office-environment.json")),
  );
  if (
    source.schemaVersion !== 2 ||
    source.namespace !== "MetaWork/OfficeDependencies" ||
    JSON.stringify(Object.keys(source.targets ?? {}).sort()) !==
      JSON.stringify([...targetKeys].sort())
  )
    throw Error("Invalid Office target manifest");
  const common = path.join(root, "src/product/skill/office_environment");
  const targets = {};
  let versions;
  for (const key of targetKeys) {
    const t = source.targets[key];
    const windows = key.startsWith("windows-");
    const arm = key.endsWith("aarch64");
    const nodeRoot = `node-v${t.node.version}-${windows ? "win" : "darwin"}-${arm ? "arm64" : "x64"}`;
    if (
      t.node.archiveRoot !== nodeRoot ||
      t.node.url !==
        `https://nodejs.org/dist/v${t.node.version}/${nodeRoot}.${windows ? "zip" : "tar.gz"}` ||
      (windows
        ? t.python.url !==
          `https://api.nuget.org/v3-flatcontainer/${arm ? "pythonarm64" : "python"}/${t.python.version}/${arm ? "pythonarm64" : "python"}.${t.python.version}.nupkg`
        : !new RegExp(
            `^https://github\\.com/astral-sh/python-build-standalone/releases/download/(\\d{8})/cpython-${t.python.version.replaceAll(".", "\\.")}%2B\\1-${arm ? "aarch64" : "x86_64"}-apple-darwin-install_only\\.tar\\.gz$`,
          ).test(t.python.url)) ||
      t.layout.pythonExecutable !==
        (windows ? "tools/python.exe" : "python/bin/python3.13") ||
      t.layout.nodeExecutable !==
        `${nodeRoot}/${windows ? "node.exe" : "bin/node"}` ||
      t.layout.npmCli !==
        `${nodeRoot}/${windows ? "node_modules" : "lib/node_modules"}/npm/bin/npm-cli.js`
    )
      throw Error("Office distribution does not match target layout");
    if (
      !/^requirements(?:\.[a-z0-9_-]+)?\.txt$/.test(t.requirements ?? "") ||
      !/^layout-[12]$/.test(t.layout?.version ?? "")
    )
      throw Error("Invalid Office target layout");
    for (const name of ["pythonExecutable", "nodeExecutable", "npmCli"]) {
      const value = t.layout[name];
      if (
        !/^[A-Za-z0-9._/-]+$/.test(value ?? "") ||
        value.startsWith("/") ||
        value.split("/").includes("..")
      )
        throw Error("Invalid Office executable layout");
    }
    const requirements = readFileSync(path.join(common, t.requirements));
    const lines = requirements.toString().trim().split(/\r?\n/);
    if (
      lines.length !== 5 ||
      lines.some(
        (line) => !/^[\w-]+==[\w.]+ --hash=sha256:[0-9a-f]{64}$/.test(line),
      )
    )
      throw Error("Invalid Office wheel lock");
    const selectedVersions = lines
      .map((line) => line.split(" ")[0])
      .sort()
      .join("\n");
    if (versions && versions !== selectedVersions)
      throw Error("Office dependency versions differ across targets");
    versions = selectedVersions;
    const result = { ...t };
    for (const [language, lock] of [
      ["python", requirements],
      ["node", readFileSync(path.join(common, "package-lock.json"))],
    ]) {
      const record = t[language],
        totals = t.downloadTotals?.[language];
      if (
        !record ||
        !/^\d+\.\d+\.\d+$/.test(record.version) ||
        !/^https:\/\/[A-Za-z0-9:/._%+-]+$/.test(record.url) ||
        !/^[0-9a-f]{64}$/.test(record.sha256) ||
        !Number.isSafeInteger(record.bytes) ||
        record.bytes <= 0 ||
        (key !== "windows-x86_64" && record.target !== key)
      )
        throw Error("Invalid Office distribution target");
      if (
        !Number.isSafeInteger(totals?.librariesBytes) ||
        totals.librariesBytes <= 0 ||
        totals.totalBytes !== record.bytes + totals.librariesBytes ||
        totals.lockSha256 !== hash(lock)
      )
        throw Error(`Remeasure Office ${language} download totals for ${key}`);
      result[language + "Id"] = hash(
        JSON.stringify(record) + lock + t.layout.version,
      );
    }
    targets[key] = result;
  }
  // These vectors precede schema migration. Preserve the exact installed paths.
  if (
    targets["windows-x86_64"].pythonId !==
      "bd948c50c30962f7f7703b852233b9ec4f98859d7b8a0dc218d311a7b41ad89c" ||
    targets["windows-x86_64"].nodeId !==
      "b7046de901f3a4d91ffa2c5b4ec5b2706bf2ab4d27f9f698405ae5204179e4d8"
  )
    throw Error("Windows x64 Office environment identity changed");
  return { ...source, targets };
}
