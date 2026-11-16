import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { readNativePackageManifest } from "./package-metadata.mjs";

const policyPath = fileURLToPath(
  new URL("../build_support/main-package-size.json", import.meta.url),
);
const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));

// Reasonable growth of the application's own code is accepted, so the whole
// installer has no upper bound: it is measured against the last released
// artifact of the same target and the difference is reported. The hard
// boundary is what the package may contain, which verifyMainPackageStage
// still owns and which no size number can buy out.
const policySchema = 2;
const baselineKeys = "artifact,bytes,sha256,version";
const versionPattern = /^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$/u;

function isRecord(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    Array.isArray(value) === false
  );
}

function keysOf(value) {
  return Object.keys(value).sort().join(",");
}

// A malformed policy document still fails immediately. Reporting instead of
// rejecting applies to the measured bytes, never to the baseline record: a
// half-written or stale-shaped baseline would turn every later delta into a
// guess, which is the failure this file exists to prevent. Every target is
// checked on every call, so one broken entry cannot ride along.
export function mainPackageSizePolicy(policy) {
  if (
    !isRecord(policy) ||
    policy.schema !== policySchema ||
    keysOf(policy) !== "schema,targets" ||
    !isRecord(policy.targets) ||
    Object.keys(policy.targets).length === 0
  )
    throw new Error("Invalid main package size policy document");
  for (const [targetId, baseline] of Object.entries(policy.targets)) {
    if (
      !isRecord(baseline) ||
      keysOf(baseline) !== baselineKeys ||
      typeof baseline.version !== "string" ||
      !versionPattern.test(baseline.version) ||
      typeof baseline.artifact !== "string" ||
      !/^[A-Za-z0-9._-]+$/u.test(baseline.artifact) ||
      typeof baseline.sha256 !== "string" ||
      !/^[a-f0-9]{64}$/u.test(baseline.sha256) ||
      !Number.isSafeInteger(baseline.bytes) ||
      baseline.bytes <= 0
    )
      throw new Error(
        `Missing or invalid main package size baseline: ${targetId}`,
      );
  }
  return policy;
}

export function mainPackageSizeBaseline(policy, targetId) {
  const baseline = mainPackageSizePolicy(policy).targets[targetId];
  if (baseline === undefined)
    throw new Error(
      `Missing or invalid main package size baseline: ${targetId}`,
    );
  return baseline;
}

function readMainPackageSizePolicy() {
  return mainPackageSizePolicy(JSON.parse(readFileSync(policyPath, "utf8")));
}

function measuredBytes(artifactPath) {
  const artifact = lstatSync(artifactPath);
  if (!artifact.isFile() || artifact.size <= 0)
    throw new Error(`Main package artifact is not measurable: ${artifactPath}`);
  return artifact.size;
}

export function formatMainPackageSizeDelta({
  bytes,
  baselineVersion,
  baselineBytes,
  deltaBytes,
  deltaPercent,
}) {
  const sign = deltaBytes < 0 ? "-" : "+";
  return `${bytes} bytes, ${sign}${Math.abs(deltaBytes)} bytes (${sign}${Math.abs(deltaPercent).toFixed(2)}%) against the ${baselineVersion} baseline of ${baselineBytes} bytes`;
}

export function reportMainPackageSize(targetId, artifactPath) {
  const baseline = mainPackageSizeBaseline(
    readMainPackageSizePolicy(),
    targetId,
  );
  const bytes = measuredBytes(artifactPath);
  const deltaBytes = bytes - baseline.bytes;
  const measurement = {
    bytes,
    baselineVersion: baseline.version,
    baselineBytes: baseline.bytes,
    deltaBytes,
    deltaPercent: (deltaBytes / baseline.bytes) * 100,
  };
  return Object.freeze({
    ...measurement,
    summary: formatMainPackageSizeDelta(measurement),
  });
}

// Moving a baseline forward replaces one target's record and keeps the rest of
// the document, including its key order, intact. The artifact has to be the
// named version's installer, so a recorded baseline is always the release it
// claims to be rather than whatever file happened to be at that path.
export function recordedMainPackageSizePolicy(
  policy,
  targetId,
  artifactPath,
  version,
) {
  mainPackageSizeBaseline(policy, targetId);
  if (typeof version !== "string" || !versionPattern.test(version))
    throw new Error(`Invalid main package release version: ${version}`);
  const artifact = path.basename(artifactPath);
  if (!artifact.includes(`-${version}-`))
    throw new Error(
      `Main package artifact ${artifact} is not a ${version} release artifact`,
    );
  return {
    ...policy,
    targets: {
      ...policy.targets,
      [targetId]: {
        version,
        artifact,
        sha256: createHash("sha256")
          .update(readFileSync(artifactPath))
          .digest("hex"),
        bytes: measuredBytes(artifactPath),
      },
    },
  };
}

// The release step that records the shipped numbers, one target at a time. The
// version comes from app.zon, the single source of truth for the release being
// packaged.
export function recordMainPackageSize(
  targetId,
  artifactPath,
  version = readNativePackageManifest(repositoryRoot).metadata.version,
) {
  const policy = recordedMainPackageSizePolicy(
    readMainPackageSizePolicy(),
    targetId,
    artifactPath,
    version,
  );
  writeFileSync(policyPath, `${JSON.stringify(policy, null, 2)}\n`);
  return Object.freeze({ targetId, ...policy.targets[targetId] });
}

export function parseMainPackageSizeArguments(args) {
  const [flag, targetId, artifactPath, ...rest] = args;
  if (
    flag !== "--record-size" ||
    rest.length !== 0 ||
    typeof targetId !== "string" ||
    typeof artifactPath !== "string" ||
    targetId.length === 0 ||
    artifactPath.length === 0 ||
    targetId.startsWith("-") ||
    artifactPath.startsWith("-")
  )
    throw new Error(
      "usage: node scripts/main-package-size.mjs --record-size <target-id> <installer-path>",
    );
  return { targetId, artifactPath };
}

export function verifyMainPackageStage(directory) {
  // Heavy Office dependencies remain optional downloads. Expanded Skill trees
  // are forbidden here; the bounded compressed built-in resource archive is
  // embedded by the build and is still main package content.
  const forbidden =
    /^(?:node_modules|node(?:\.exe)?|python(?:[0-9.]*|w)?(?:\.exe)?|python[0-9]+\.dll|libpython.*|soffice(?:\.exe|\.bin)?|libreoffice.*|docx|xlsx|pptx)$|\.(?:whl|pyd)$/iu;
  let files = 0;
  function visit(current) {
    for (const name of readdirSync(current)) {
      const entry = path.join(current, name);
      if (forbidden.test(name))
        throw new Error(
          `Office dependency is not allowed in the main package: ${path.relative(directory, entry)}`,
        );
      const info = lstatSync(entry);
      if (info.isDirectory()) visit(entry);
      else if (info.isFile()) files += 1;
      else throw new Error(`Unsupported main package entry: ${entry}`);
    }
  }
  visit(directory);
  if (files === 0) throw new Error("Main package stage is empty");
  return { files };
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : null;
if (invokedPath === import.meta.url) {
  try {
    const { targetId, artifactPath } = parseMainPackageSizeArguments(
      process.argv.slice(2),
    );
    const recorded = recordMainPackageSize(targetId, artifactPath);
    console.log(
      `recorded ${targetId} main package baseline ${recorded.version}: ${recorded.artifact} ${recorded.bytes} bytes (sha256=${recorded.sha256})`,
    );
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
