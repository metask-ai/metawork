import { lstatSync, readdirSync } from "node:fs";
import path from "node:path";

// What the main package may contain, which is the one boundary a number could
// never buy out: a few-MB installer is the product's own advantage, and it
// survives only because interpreters, document libraries and expanded resource
// trees are forbidden here rather than merely discouraged. Heavy Office
// dependencies remain optional downloads. The installer's total size has no
// upper bound and no recorded baseline; packaging prints the measured bytes and
// digest of what it produced, and the authoritative record of a released
// artifact is its own content-length on the download host.
export function verifyMainPackageStage(directory) {
  // Expanded Skill trees are forbidden here; the bounded compressed built-in
  // resource archive is embedded by the build and is still main package
  // content.
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
