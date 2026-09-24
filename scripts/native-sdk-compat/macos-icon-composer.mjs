import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  utimesSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export const macosAppIconName = "MetaWork";
export const supportedActoolVersions = Object.freeze([
  Object.freeze({ bundleVersion: "24765", shortVersion: "26.6" }),
  Object.freeze({ bundleVersion: "25098", shortVersion: "27.0" }),
]);

const nativeSdkFallbackIconName = "AppIcon.icns";
const iconAssetName = "app-icon.png";
const compiledAssetCatalogName = "Assets.car";
const compiledFallbackIconName = `${macosAppIconName}.icns`;
const partialPlistName = "partial.plist";

function combinedOutput(result) {
  return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

function run(command, args) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: "pipe",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(
      `${path.basename(command)} ${args.join(" ")} failed with exit code ${result.status}\n${combinedOutput(result).trim()}`,
    );
  }
  return result;
}

function fileDigest(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function requireRegularFile(filePath, label) {
  if (!existsSync(filePath) || !lstatSync(filePath).isFile()) {
    throw new Error(`${label} is not a regular file: ${filePath}`);
  }
  return filePath;
}

function requireExactKeys(value, expectedKeys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${label} keys are ${actual.join(", ")}, expected ${expected.join(", ")}`,
    );
  }
}

function sourceEntries(root, directory = root) {
  const entries = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = path.join(directory, entry.name);
    const relativePath = path
      .relative(root, absolutePath)
      .split(path.sep)
      .join("/");
    if (entry.isDirectory()) {
      entries.push(`${relativePath}/`);
      entries.push(...sourceEntries(root, absolutePath));
    } else if (entry.isFile()) {
      entries.push(relativePath);
    } else {
      throw new Error(
        `macOS Icon Composer source contains a non-regular entry: ${relativePath}`,
      );
    }
  }
  return entries.sort();
}

export function parseActoolVersionReport(output) {
  const shortVersion = output.match(
    /<key>short-bundle-version<\/key>\s*<string>([^<]+)<\/string>/u,
  )?.[1];
  const bundleVersion = output.match(
    /<key>bundle-version<\/key>\s*<string>([^<]+)<\/string>/u,
  )?.[1];
  if (!shortVersion || !bundleVersion) {
    throw new Error("actool version report is missing typed version fields");
  }
  return Object.freeze({ bundleVersion, shortVersion });
}

export function requireSupportedActoolVersion(version) {
  const supported = supportedActoolVersions.some(
    (candidate) =>
      candidate.shortVersion === version.shortVersion &&
      candidate.bundleVersion === version.bundleVersion,
  );
  if (!supported) {
    throw new Error(
      `unsupported actool ${version.shortVersion} (${version.bundleVersion}); review Icon Composer output before extending the allowlist`,
    );
  }
  return version;
}

export function validateMacosIconComposerSource(sourcePath, canonicalPngPath) {
  if (!existsSync(sourcePath) || !lstatSync(sourcePath).isDirectory()) {
    throw new Error(`macOS Icon Composer source is missing: ${sourcePath}`);
  }
  const entries = sourceEntries(sourcePath);
  const expectedEntries = ["Assets/", `Assets/${iconAssetName}`, "icon.json"];
  if (JSON.stringify(entries) !== JSON.stringify(expectedEntries)) {
    throw new Error(
      `macOS Icon Composer source entries are ${entries.join(", ")}, expected ${expectedEntries.join(", ")}`,
    );
  }

  const iconJsonPath = requireRegularFile(
    path.join(sourcePath, "icon.json"),
    "Icon Composer manifest",
  );
  const iconAssetPath = requireRegularFile(
    path.join(sourcePath, "Assets", iconAssetName),
    "Icon Composer artwork",
  );
  requireRegularFile(canonicalPngPath, "canonical app icon PNG");
  if (fileDigest(iconAssetPath) !== fileDigest(canonicalPngPath)) {
    throw new Error(
      "Icon Composer artwork must be byte-identical to assets/icons/app-icon.png",
    );
  }

  let manifest;
  try {
    manifest = JSON.parse(readFileSync(iconJsonPath, "utf8"));
  } catch {
    throw new Error("Icon Composer manifest is not valid JSON");
  }
  requireExactKeys(
    manifest,
    ["fill", "groups", "supported-platforms"],
    "Icon Composer manifest",
  );
  requireExactKeys(manifest.fill, ["solid"], "Icon Composer fill");
  if (manifest.fill.solid !== "extended-gray:1.00000,1.00000") {
    throw new Error("Icon Composer background must be a solid white fill");
  }
  requireExactKeys(
    manifest["supported-platforms"],
    ["squares"],
    "Icon Composer supported platforms",
  );
  if (
    JSON.stringify(manifest["supported-platforms"].squares) !==
    JSON.stringify(["macOS"])
  ) {
    throw new Error("Icon Composer source must target only macOS squares");
  }
  if (!Array.isArray(manifest.groups) || manifest.groups.length !== 1) {
    throw new Error("Icon Composer source must contain exactly one flat group");
  }

  const group = manifest.groups[0];
  requireExactKeys(
    group,
    [
      "blur-material",
      "hidden",
      "layers",
      "lighting",
      "shadow",
      "specular",
      "translucency",
    ],
    "Icon Composer group",
  );
  if (
    group["blur-material"] !== null ||
    group.hidden !== false ||
    group.lighting !== "individual" ||
    group.specular !== false
  ) {
    throw new Error(
      "Icon Composer group material effects must remain disabled",
    );
  }
  requireExactKeys(group.shadow, ["kind", "opacity"], "Icon Composer shadow");
  if (group.shadow.kind !== "none" || group.shadow.opacity !== 0) {
    throw new Error("Icon Composer group shadow must remain disabled");
  }
  requireExactKeys(
    group.translucency,
    ["enabled", "value"],
    "Icon Composer translucency",
  );
  if (group.translucency.enabled !== false || group.translucency.value !== 0) {
    throw new Error("Icon Composer translucency must remain disabled");
  }
  if (!Array.isArray(group.layers) || group.layers.length !== 1) {
    throw new Error(
      "Icon Composer group must contain exactly one artwork layer",
    );
  }
  const layer = group.layers[0];
  requireExactKeys(
    layer,
    ["glass", "hidden", "image-name", "name"],
    "Icon Composer layer",
  );
  if (
    layer.glass !== false ||
    layer.hidden !== false ||
    layer["image-name"] !== iconAssetName ||
    layer.name !== macosAppIconName
  ) {
    throw new Error(
      "Icon Composer layer must use the canonical artwork with glass effects disabled",
    );
  }
  return Object.freeze({ iconAssetPath, iconJsonPath, sourcePath });
}

export function macosIconActoolArguments(sourcePath, outputPath) {
  return [
    "actool",
    sourcePath,
    "--compile",
    outputPath,
    "--app-icon",
    macosAppIconName,
    "--enable-on-demand-resources",
    "NO",
    "--development-region",
    "en",
    "--target-device",
    "mac",
    "--platform",
    "macosx",
    "--include-all-app-icons",
    "--minimum-deployment-target",
    "11.0",
    "--output-partial-info-plist",
    path.posix.join(outputPath, partialPlistName),
    "--output-format",
    "human-readable-text",
  ];
}

function readCompiledPartialPlist(plistPath) {
  const report = run("/usr/bin/plutil", [
    "-convert",
    "json",
    "-o",
    "-",
    plistPath,
  ]);
  let value;
  try {
    value = JSON.parse(report.stdout);
  } catch {
    throw new Error("actool partial plist is not valid JSON");
  }
  requireExactKeys(
    value,
    ["CFBundleIconFile", "CFBundleIconName"],
    "actool partial plist",
  );
  if (
    value.CFBundleIconFile !== macosAppIconName ||
    value.CFBundleIconName !== macosAppIconName
  ) {
    throw new Error(
      "actool partial plist contains an unexpected icon identity",
    );
  }
  return Object.freeze(value);
}

function validateCompiledArtifact(outputPath, actoolVersion) {
  const entries = sourceEntries(outputPath);
  const expectedEntries = [
    compiledAssetCatalogName,
    compiledFallbackIconName,
    partialPlistName,
  ].sort();
  if (JSON.stringify(entries) !== JSON.stringify(expectedEntries)) {
    throw new Error(
      `actool outputs are ${entries.join(", ")}, expected ${expectedEntries.join(", ")}`,
    );
  }
  const assetCatalogPath = requireRegularFile(
    path.join(outputPath, compiledAssetCatalogName),
    "compiled asset catalog",
  );
  const fallbackIconPath = requireRegularFile(
    path.join(outputPath, compiledFallbackIconName),
    "compiled fallback icon",
  );
  const partialPlistPath = requireRegularFile(
    path.join(outputPath, partialPlistName),
    "compiled partial plist",
  );
  const assetBytes = readFileSync(assetCatalogPath);
  const iconBytes = readFileSync(fallbackIconPath);
  if (
    assetBytes.length < 8 ||
    assetBytes.subarray(0, 8).toString("ascii") !== "BOMStore"
  ) {
    throw new Error("compiled Assets.car does not have a BOMStore header");
  }
  if (
    iconBytes.length < 8 ||
    iconBytes.subarray(0, 4).toString("ascii") !== "icns"
  ) {
    throw new Error("compiled fallback icon does not have an icns header");
  }
  readCompiledPartialPlist(partialPlistPath);
  return Object.freeze({
    actoolVersion,
    assetCatalogDigest: fileDigest(assetCatalogPath),
    assetCatalogPath,
    fallbackIconDigest: fileDigest(fallbackIconPath),
    fallbackIconPath,
    outputPath,
  });
}

export function compileMacosAppIcon(sourcePath, canonicalPngPath) {
  if (process.platform !== "darwin") {
    throw new Error("macOS Icon Composer packaging requires macOS");
  }
  validateMacosIconComposerSource(sourcePath, canonicalPngPath);
  const actoolVersion = requireSupportedActoolVersion(
    parseActoolVersionReport(
      run("/usr/bin/xcrun", ["actool", "--version"]).stdout,
    ),
  );
  const outputPath = mkdtempSync(
    path.join(tmpdir(), "metawork-macos-app-icon-"),
  );
  try {
    const result = run(
      "/usr/bin/xcrun",
      macosIconActoolArguments(sourcePath, outputPath),
    );
    if (/\bwarning:/iu.test(combinedOutput(result))) {
      throw new Error(
        `actool emitted a warning\n${combinedOutput(result).trim()}`,
      );
    }
    return validateCompiledArtifact(outputPath, actoolVersion);
  } catch (error) {
    rmSync(outputPath, { recursive: true, force: true });
    throw error;
  }
}

function readPlistString(plistPath, key) {
  return run("/usr/bin/plutil", [
    "-extract",
    key,
    "raw",
    "-o",
    "-",
    plistPath,
  ]).stdout.trim();
}

function replacePlistString(plistPath, key, value) {
  run("/usr/bin/plutil", ["-replace", key, "-string", value, plistPath]);
}

function insertPlistString(plistPath, key, value) {
  run("/usr/bin/plutil", ["-insert", key, "-string", value, plistPath]);
}

export function stageMacosAppIcon(artifact, appPath) {
  const contentsPath = path.join(appPath, "Contents");
  const resourcesPath = path.join(contentsPath, "Resources");
  const plistPath = requireRegularFile(
    path.join(contentsPath, "Info.plist"),
    "packaged app Info.plist",
  );
  if (!existsSync(resourcesPath) || !lstatSync(resourcesPath).isDirectory()) {
    throw new Error(
      `packaged app Resources directory is missing: ${resourcesPath}`,
    );
  }
  if (
    readPlistString(plistPath, "CFBundleIconFile") !== nativeSdkFallbackIconName
  ) {
    throw new Error(
      `Native SDK packaged icon identity changed; expected ${nativeSdkFallbackIconName}`,
    );
  }
  const nativeFallbackPath = requireRegularFile(
    path.join(resourcesPath, nativeSdkFallbackIconName),
    "Native SDK fallback icon",
  );
  const assetCatalogPath = path.join(resourcesPath, compiledAssetCatalogName);
  const fallbackIconPath = path.join(resourcesPath, compiledFallbackIconName);
  if (existsSync(assetCatalogPath) || existsSync(fallbackIconPath)) {
    throw new Error(
      "packaged app already contains Icon Composer resources; review the Native SDK capability before staging the compatibility seam",
    );
  }

  copyFileSync(artifact.assetCatalogPath, assetCatalogPath);
  copyFileSync(artifact.fallbackIconPath, fallbackIconPath);
  rmSync(nativeFallbackPath);
  replacePlistString(plistPath, "CFBundleIconFile", macosAppIconName);
  try {
    readPlistString(plistPath, "CFBundleIconName");
    replacePlistString(plistPath, "CFBundleIconName", macosAppIconName);
  } catch {
    insertPlistString(plistPath, "CFBundleIconName", macosAppIconName);
  }
  const staged = verifyStagedMacosAppIcon(artifact, appPath);
  const now = new Date();
  utimesSync(appPath, now, now);
  return staged;
}

export function verifyStagedMacosAppIcon(artifact, appPath) {
  const contentsPath = path.join(appPath, "Contents");
  const resourcesPath = path.join(contentsPath, "Resources");
  const plistPath = path.join(contentsPath, "Info.plist");
  const assetCatalogPath = requireRegularFile(
    path.join(resourcesPath, compiledAssetCatalogName),
    "packaged Assets.car",
  );
  const fallbackIconPath = requireRegularFile(
    path.join(resourcesPath, compiledFallbackIconName),
    "packaged fallback icon",
  );
  if (existsSync(path.join(resourcesPath, nativeSdkFallbackIconName))) {
    throw new Error("packaged app retained the superseded Native SDK app icon");
  }
  if (
    statSync(assetCatalogPath).size === 0 ||
    fileDigest(assetCatalogPath) !== artifact.assetCatalogDigest ||
    statSync(fallbackIconPath).size === 0 ||
    fileDigest(fallbackIconPath) !== artifact.fallbackIconDigest
  ) {
    throw new Error(
      "packaged Icon Composer resources differ from actool output",
    );
  }
  for (const key of ["CFBundleIconFile", "CFBundleIconName"]) {
    if (readPlistString(plistPath, key) !== macosAppIconName) {
      throw new Error(`packaged Info.plist ${key} must be ${macosAppIconName}`);
    }
  }
  return Object.freeze({ assetCatalogPath, fallbackIconPath });
}

export function removeCompiledMacosAppIcon(artifact) {
  rmSync(artifact.outputPath, { recursive: true, force: true });
}
