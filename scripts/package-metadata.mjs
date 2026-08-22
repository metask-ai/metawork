import { readFileSync } from "node:fs";
import path from "node:path";

export function parseNativeProductIdentity(manifest) {
  const bundleId = manifest.match(/^\s*\.id = "([^"]+)",?$/mu)?.[1];
  const executableName = manifest.match(/^\s*\.name = "([^"]+)",?$/mu)?.[1];
  if (
    !bundleId ||
    !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/u.test(bundleId) ||
    !executableName ||
    !/^[A-Za-z0-9._-]+$/u.test(executableName)
  ) {
    throw new Error("app.zon has an invalid native product identity");
  }
  return Object.freeze({ bundleId, executableName });
}

export function parseNativePackageMetadata(manifest) {
  const displayName = manifest.match(
    /^\s*\.display_name = "([^"]+)",?$/mu,
  )?.[1];
  const version = manifest.match(/^\s*\.version = "([^"]+)",?$/mu)?.[1];
  if (
    !displayName ||
    !/^[A-Za-z0-9._-]+$/u.test(displayName) ||
    !version ||
    !/^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$/u.test(version)
  ) {
    throw new Error("app.zon has invalid native package metadata");
  }
  return Object.freeze({ displayName, version });
}

export function readNativePackageManifest(repositoryRoot) {
  const manifest = readFileSync(path.join(repositoryRoot, "app.zon"), "utf8");
  return Object.freeze({
    identity: parseNativeProductIdentity(manifest),
    metadata: parseNativePackageMetadata(manifest),
  });
}
