import { lstatSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const policyPath = fileURLToPath(
  new URL("../build_support/main-package-size.json", import.meta.url),
);

export function verifyMainPackageSize(targetId, artifactPath) {
  const policy = JSON.parse(readFileSync(policyPath, "utf8"));
  const baseline = policy.targets?.[targetId];
  if (
    policy.schema !== 1 ||
    !baseline ||
    !Number.isSafeInteger(baseline.bytes) ||
    baseline.bytes <= 0 ||
    !Number.isSafeInteger(baseline.allowanceBytes) ||
    baseline.allowanceBytes < 0 ||
    !/^[a-f0-9]{64}$/u.test(baseline.sha256)
  )
    throw new Error(
      `Missing or invalid main package size baseline: ${targetId}`,
    );
  const artifact = lstatSync(artifactPath);
  const maximumBytes = baseline.bytes + baseline.allowanceBytes;
  if (!artifact.isFile() || artifact.size <= 0 || artifact.size > maximumBytes)
    throw new Error(
      `Main package size rejected for ${targetId}: ${artifact.size} bytes; maximum ${maximumBytes} bytes (${policy.baselineVersion} baseline ${baseline.bytes} + allowance ${baseline.allowanceBytes})`,
    );
  return { bytes: artifact.size, maximumBytes };
}

export function verifyMainPackageStage(directory) {
  // Heavy Office dependencies remain optional downloads. Expanded Skill trees
  // are forbidden here; the separately pinned, bounded self-owned seed is
  // embedded by the build and still counts toward the whole installer budget.
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
