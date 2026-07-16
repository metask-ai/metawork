import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { bundleFiles, validateAgentCoreBundle } from "./agentcore-bundle.mjs";

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function fixture(t, mutateManifest = () => {}) {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-bundle-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const files = {};
  for (const relativePath of bundleFiles) {
    const content = `fixture:${relativePath}`;
    await mkdir(path.dirname(path.join(root, relativePath)), {
      recursive: true,
    });
    await writeFile(path.join(root, relativePath), content);
    files[relativePath] = { sha256: digest(content) };
  }
  const manifest = {
    schema_version: 1,
    name: "metacodes-agentcore",
    version: "0.0.0-test+0123456789ab",
    source: {
      cc_zig_commit: "0123456789abcdef0123456789abcdef01234567",
      dirty: false,
    },
    toolchain: { zig_version: "0.16.0" },
    build: {
      resolved_target: "aarch64-macos.13.0...15.6-none",
      architecture: "aarch64",
      os: "macos",
      macos_deployment_target: "13.0",
      optimize: "ReleaseSafe",
    },
    contract: {
      binary_abi_version: 1,
      required_system_link_inputs: ["libc"],
      ui_request_mode: "synchronous",
    },
    files,
  };
  mutateManifest(manifest);
  await writeFile(path.join(root, "manifest.json"), JSON.stringify(manifest));
  return root;
}

const injectedChecks = {
  platform: "darwin",
  architecture: "arm64",
  zigVersion: "0.16.0",
  symbols: "0000000000000000 T _metacodes_agentcore_get_api\n",
};

test("accepts a complete pinned macOS arm64 bundle", async (t) => {
  const root = await fixture(t);
  const result = await validateAgentCoreBundle(root, injectedChecks);
  assert.equal(result.target, "aarch64-macos.13.0");
});

test("rejects a checksum mismatch", async (t) => {
  const root = await fixture(t);
  await writeFile(path.join(root, bundleFiles[0]), "corrupt");
  await assert.rejects(
    validateAgentCoreBundle(root, injectedChecks),
    /checksum mismatch/,
  );
});

test("rejects a self-consistent bundle that differs from the repository lock", async (t) => {
  const root = await fixture(t);
  const expectedManifest = JSON.parse(
    await readFile(path.join(root, "manifest.json"), "utf8"),
  );
  expectedManifest.version = "0.0.0-another-build";
  await assert.rejects(
    validateAgentCoreBundle(root, { ...injectedChecks, expectedManifest }),
    /repository lock/,
  );
});

test("rejects a missing or extra manifest artifact", async (t) => {
  const root = await fixture(t, (manifest) => {
    delete manifest.files[bundleFiles[1]];
  });
  await assert.rejects(
    validateAgentCoreBundle(root, injectedChecks),
    /file set/,
  );
});

test("rejects an unlisted file in the bundle filesystem", async (t) => {
  const root = await fixture(t);
  await writeFile(path.join(root, "sdk", "stale.zig"), "stale");
  await assert.rejects(
    validateAgentCoreBundle(root, injectedChecks),
    /filesystem contains missing or unknown entries/,
  );
});

test("rejects a bundle for another target", async (t) => {
  const root = await fixture(t);
  await assert.rejects(
    validateAgentCoreBundle(root, { ...injectedChecks, architecture: "x64" }),
    /unsupported AgentCore host architecture/,
  );
});

test("rejects a dirty bundle without its source digest", async (t) => {
  const root = await fixture(t, (manifest) => {
    manifest.source.dirty = true;
  });
  await assert.rejects(
    validateAgentCoreBundle(root, injectedChecks),
    /dirty_source_sha256/,
  );
});

test("rejects a missing or duplicated discovery symbol", async (t) => {
  const root = await fixture(t);
  await assert.rejects(
    validateAgentCoreBundle(root, { ...injectedChecks, symbols: "" }),
    /exactly one discovery symbol/,
  );
  await assert.rejects(
    validateAgentCoreBundle(root, {
      ...injectedChecks,
      symbols:
        "T _metacodes_agentcore_get_api\nT _metacodes_agentcore_get_api\n",
    }),
    /exactly one discovery symbol/,
  );
});
