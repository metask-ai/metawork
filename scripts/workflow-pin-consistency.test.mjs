import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

// The Inno Setup pin is declared by hand in both workflows, because a release
// is packaged from a tag and the gate runs on a pull request, and nothing in
// Actions YAML shares one value between two workflow files. The duplication is
// deliberate; what it cannot survive is one side moving alone. A gate that
// compiled the installer with a different compiler than the release machine
// uses would still go green and would stop meaning anything, and nothing about
// such a change looks wrong in a diff of either file on its own.
//
// Asserted as text, like scripts/architecture-boundaries.test.mjs does against
// build.zig, rather than by parsing YAML: these are two declarations and one
// assignment, and a parser would be a dependency bought for three lines.
//
// Deliberately not a whole-step comparison. The gate's copy of the install
// step carries `if: runner.os == 'Windows'` and its own comments, so equality
// of the step text would fail the moment either file is edited for a reason
// that has nothing to do with the pin.
const workflows = {
  "ci.yml": ".github/workflows/ci.yml",
  "release.yml": ".github/workflows/release.yml",
};

function declaration(name, file) {
  const matches = [
    ...read(workflows[file]).matchAll(
      new RegExp(String.raw`^\s*${name}:\s*(\S+)\s*$`, "gmu"),
    ),
  ];
  assert.equal(
    matches.length,
    1,
    `.github/workflows/${file} should declare ${name} exactly once, found ${matches.length}. Both this workflow and the other one pin the Inno Setup compiler, and the pin has to stay a single declaration in each so the two can be compared.`,
  );
  return matches[0][1];
}

const together =
  "Change both: .github/workflows/release.yml installs the compiler a release is built with, and .github/workflows/ci.yml installs the compiler the packaging gate verifies with. If they disagree, the gate passes against an installer no release ships.";

test("both workflows pin the same Inno Setup download", () => {
  const url = {
    ci: declaration("INNO_SETUP_URL", "ci.yml"),
    release: declaration("INNO_SETUP_URL", "release.yml"),
  };
  assert.match(
    url.release,
    /^https:\/\/\S+$/u,
    `INNO_SETUP_URL in .github/workflows/release.yml is not an absolute https URL: ${url.release}`,
  );
  assert.equal(url.ci, url.release, `INNO_SETUP_URL differs. ${together}`);
});

test("both workflows pin the same Inno Setup digest", () => {
  const digest = {
    ci: declaration("INNO_SETUP_SHA256", "ci.yml"),
    release: declaration("INNO_SETUP_SHA256", "release.yml"),
  };
  assert.match(
    digest.release,
    /^[0-9a-f]{64}$/u,
    `INNO_SETUP_SHA256 in .github/workflows/release.yml is not a lowercase SHA-256 digest: ${digest.release}`,
  );
  assert.equal(
    digest.ci,
    digest.release,
    `INNO_SETUP_SHA256 differs. ${together} A digest that moved without the URL, or the other way round, is the same defect.`,
  );
});

test("both workflows point the packaging script at the compiler they installed", () => {
  for (const file of Object.keys(workflows)) {
    const pointed = read(workflows[file])
      .split("\n")
      .some(
        (line) =>
          line.includes("METAWORK_INNO_SETUP_COMPILER=") &&
          line.includes("GITHUB_ENV"),
      );
    assert.ok(
      pointed,
      `.github/workflows/${file} no longer writes METAWORK_INNO_SETUP_COMPILER to GITHUB_ENV. Without it scripts/package-windows.mjs discovers a compiler through PATH, which on these images is the preinstalled Inno Setup 6 that cannot build this installer at all, so the pin above would be installed and then ignored. ${together}`,
    );
  }
});
