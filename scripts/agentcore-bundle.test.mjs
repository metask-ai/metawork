import { createHash } from "node:crypto";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  readdir,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { validateAgentCoreBundle } from "./agentcore-bundle.mjs";
import { stageAgentCoreBundle } from "./stage-agentcore-bundle.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";
import {
  stageAgentCoreRuntimeAssets,
  verifyAgentCoreRuntimeAssets,
} from "./agentcore-runtime-assets.mjs";

const fixtureFiles = [
  "lib/metask_agentcore.lib",
  "lib/metask_agentcore.dll",
  "include/metask/agentcore.h",
  "bindings/zig/build.zig",
  "bindings/zig/build.zig.zon",
  "bindings/zig/src/root.zig",
  "bindings/zig/src/protocol.zig",
  "bindings/zig/src/types.zig",
  "bindings/rust/Cargo.toml",
  "bindings/rust/Cargo.lock",
  "bindings/rust/link.cfg",
  "bindings/rust/build.rs",
  "bindings/rust/src/lib.rs",
  "bindings/rust/src/raw.rs",
  "bindings/rust/examples/link_probe.rs",
  "README.md",
  "bin/rg.exe",
  "bin/ripgrep-LICENSE-MIT",
];

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function fixture(t, mutateManifest = () => {}) {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-bundle-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const files = [];
  for (const relativePath of fixtureFiles) {
    const content = `fixture:${relativePath}`;
    await mkdir(path.dirname(path.join(root, relativePath)), {
      recursive: true,
    });
    await writeFile(path.join(root, relativePath), content);
    files.push({ path: relativePath, sha256: digest(content) });
  }
  const manifest = {
    schema_version: 1,
    vendor: "metask",
    name: "agentcore",
    version: "0.1.0-dev+0123456789ab",
    source: {
      commit: "0123456789abcdef0123456789abcdef01234567",
      dirty: false,
    },
    toolchain: { zig_version: "0.16.0" },
    target: {
      id: "x86_64-windows-gnu",
      architecture: "x86_64",
      os: "windows",
      abi: "gnu",
      zig_target: "x86_64-windows.win10...win11_dt-gnu",
      rust_target: "x86_64-pc-windows-gnu",
    },
    build: {
      optimize: "ReleaseSafe",
      strip: true,
    },
    link: {
      requires_c_runtime: true,
      system_libraries: ["advapi32", "crypt32"],
      system_frameworks: [],
    },
    contract: {
      binary_abi_status: "experimental",
      binary_abi_version: 1,
      binary_abi_revision: 18,
      binary_abi_table_size: 64,
    },
    shared_library: {
      path: "lib/metask_agentcore.dll",
      entry_point: "metask_agentcore_get_api",
      install_name: null,
      needed: ["KERNEL32.dll"],
    },
    runtime_assets: [
      {
        name: "ripgrep",
        version: "14.1.1",
        revision: "4649aa9700",
        path: "bin/rg.exe",
        upstream: "https://github.com/BurntSushi/ripgrep",
        license: "MIT OR Unlicense",
        role: "Glob/Grep execution dependency",
      },
    ],
    files,
  };
  mutateManifest(manifest);
  if (manifest.target.os === "macos") {
    manifest.shared_library = {
      path: "lib/libmetask_agentcore.dylib",
      entry_point: "metask_agentcore_get_api",
      install_name: "@rpath/libmetask_agentcore.dylib",
      needed: ["/usr/lib/libSystem.B.dylib"],
    };
    manifest.files.find(
      (file) => file.path === "lib/metask_agentcore.dll",
    ).path = "lib/libmetask_agentcore.dylib";
    await rename(
      path.join(root, "lib/metask_agentcore.dll"),
      path.join(root, "lib/libmetask_agentcore.dylib"),
    );
    manifest.runtime_assets[0].path = "bin/rg";
    manifest.files.find((file) => file.path === "bin/rg.exe").path = "bin/rg";
    await rename(path.join(root, "bin/rg.exe"), path.join(root, "bin/rg"));
  }
  await writeFile(path.join(root, "manifest.json"), JSON.stringify(manifest));
  return { root, manifest };
}

async function macosFixture(t, targetId) {
  const x64 = targetId === "x86_64-macos";
  const candidate = await fixture(t, (manifest) => {
    manifest.target = {
      id: targetId,
      architecture: x64 ? "x86_64" : "aarch64",
      os: "macos",
      abi: "none",
      zig_target: `${x64 ? "x86_64" : "aarch64"}-macos.13.0...15.6-none`,
      rust_target: `${x64 ? "x86_64" : "aarch64"}-apple-darwin`,
    };
    manifest.link.system_libraries = [];
    manifest.files[0].path = "lib/libmetask_agentcore.a";
  });
  await rename(
    path.join(candidate.root, "lib", "metask_agentcore.lib"),
    path.join(candidate.root, "lib", "libmetask_agentcore.a"),
  );
  await writeFile(
    path.join(candidate.root, "manifest.json"),
    JSON.stringify(candidate.manifest),
  );
  return candidate;
}

async function repository(t, manifest) {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-repository-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const lockRoot = path.join(root, "build_support");
  await mkdir(lockRoot, { recursive: true });
  for (const lockName of [
    "agentcore-bundle.windows-aarch64.lock.json",
    "agentcore-bundle.windows-x86_64.lock.json",
    "agentcore-bundle.macos-aarch64.lock.json",
    "agentcore-bundle.macos-x86_64.lock.json",
  ]) {
    await writeFile(path.join(lockRoot, lockName), JSON.stringify(manifest));
  }
  return root;
}

const injectedChecks = {
  platform: "win32",
  architecture: "x64",
  zigVersion: "0.16.0",
  symbols: "00000000 T metask_agentcore_get_api\n",
};
const injectedVerification = {
  targetId: "x86_64-windows-gnu",
  validationOptions: injectedChecks,
};

function injectedFileOperations(overrides = {}) {
  return { copyFile, rename, rm, ...overrides };
}

async function seedCanonicalBundle(repositoryRoot) {
  const storageRoot = path.join(repositoryRoot, ".agentcore", "bundles");
  const target = path.join(storageRoot, "x86_64-windows-gnu");
  await mkdir(target, { recursive: true });
  await writeFile(path.join(target, "old"), "old-canonical");
  return { storageRoot, target };
}

test("accepts a locked revision 18 Windows x64 GNU candidate", async (t) => {
  const { root, manifest } = await fixture(t);
  const result = await validateAgentCoreBundle(root, {
    ...injectedChecks,
    expectedManifest: manifest,
  });
  assert.equal(result.target, "x86_64-windows.win10...win11_dt-gnu");
  assert.deepEqual(result.payloadFiles, fixtureFiles);
});

test("accepts a locked revision 18 Windows ARM64 GNU candidate", async (t) => {
  const { root, manifest } = await fixture(t, (manifest) => {
    manifest.target = {
      id: "aarch64-windows-gnu",
      architecture: "aarch64",
      os: "windows",
      abi: "gnu",
      zig_target: "aarch64-windows.win10...win11_dt-gnu",
      rust_target: "aarch64-pc-windows-gnullvm",
    };
  });
  const result = await validateAgentCoreBundle(root, {
    ...injectedChecks,
    expectedManifest: manifest,
  });
  assert.equal(result.target, "aarch64-windows.win10...win11_dt-gnu");
  assert.deepEqual(result.payloadFiles, fixtureFiles);
});

test("accepts a locked revision 18 macOS arm64 candidate", async (t) => {
  const candidate = await fixture(t, (manifest) => {
    manifest.target = {
      id: "aarch64-macos",
      architecture: "aarch64",
      os: "macos",
      abi: "none",
      zig_target: "aarch64-macos.13.0...15.6-none",
      rust_target: "aarch64-apple-darwin",
    };
    manifest.link.system_libraries = [];
    manifest.files[0].path = "lib/libmetask_agentcore.a";
  });
  await mkdir(path.join(candidate.root, "lib"), { recursive: true });
  await rename(
    path.join(candidate.root, "lib", "metask_agentcore.lib"),
    path.join(candidate.root, "lib", "libmetask_agentcore.a"),
  );
  await writeFile(
    path.join(candidate.root, "manifest.json"),
    JSON.stringify(candidate.manifest),
  );
  const result = await validateAgentCoreBundle(candidate.root, {
    platform: "darwin",
    architecture: "arm64",
    zigVersion: "0.16.0",
    symbols: "00000000 T metask_agentcore_get_api\n",
    expectedManifest: candidate.manifest,
  });
  assert.equal(result.target, "aarch64-macos.13.0...15.6-none");
  assert.equal(path.basename(result.libraryPath), "libmetask_agentcore.a");
});

test("accepts a locked revision 18 macOS x64 candidate when cross-building on arm64 macOS", async (t) => {
  const candidate = await fixture(t, (manifest) => {
    manifest.target = {
      id: "x86_64-macos",
      architecture: "x86_64",
      os: "macos",
      abi: "none",
      zig_target: "x86_64-macos.13.0...15.6-none",
      rust_target: "x86_64-apple-darwin",
    };
    manifest.link.system_libraries = [];
    manifest.files[0].path = "lib/libmetask_agentcore.a";
  });
  await mkdir(path.join(candidate.root, "lib"), { recursive: true });
  await rename(
    path.join(candidate.root, "lib", "metask_agentcore.lib"),
    path.join(candidate.root, "lib", "libmetask_agentcore.a"),
  );
  await writeFile(
    path.join(candidate.root, "manifest.json"),
    JSON.stringify(candidate.manifest),
  );
  const result = await validateAgentCoreBundle(candidate.root, {
    platform: "darwin",
    architecture: "arm64",
    zigVersion: "0.16.0",
    symbols: "00000000 T metask_agentcore_get_api\n",
    expectedManifest: candidate.manifest,
  });
  assert.equal(result.target, "x86_64-macos.13.0...15.6-none");
  assert.equal(path.basename(result.libraryPath), "libmetask_agentcore.a");
});

test("rejects a checksum mismatch", async (t) => {
  const { root } = await fixture(t);
  await writeFile(path.join(root, fixtureFiles[0]), "corrupt");
  await assert.rejects(
    validateAgentCoreBundle(root, injectedChecks),
    /checksum mismatch/,
  );
});

test("requires the exact runtime asset declaration and checksum-pinned license", async (t) => {
  for (const mutate of [
    (manifest) => {
      delete manifest.runtime_assets;
    },
    (manifest) => {
      manifest.runtime_assets = [];
    },
    (manifest) => {
      manifest.runtime_assets.push(manifest.runtime_assets[0]);
    },
    (manifest) => {
      manifest.runtime_assets[0].path = "../rg.exe";
    },
    (manifest) => {
      manifest.runtime_assets[0].unrecognized = true;
    },
    (manifest) => {
      manifest.files = manifest.files.filter(
        (file) => file.path !== "bin/ripgrep-LICENSE-MIT",
      );
    },
    (manifest) => {
      manifest.files = manifest.files.filter(
        (file) => file.path !== "bin/rg.exe",
      );
    },
  ]) {
    const candidate = await fixture(t, mutate);
    await assert.rejects(
      validateAgentCoreBundle(candidate.root, injectedChecks),
      /manifest contract|runtime.asset|checksum-pinned/,
    );
  }
});

test("deploys only pinned runtime assets and rejects missing or tampered deployment", async (t) => {
  const candidate = await fixture(t);
  const bundle = await validateAgentCoreBundle(candidate.root, injectedChecks);
  const destination = await mkdtemp(
    path.join(tmpdir(), "metawork-runtime-assets-"),
  );
  t.after(() => rm(destination, { recursive: true, force: true }));
  await stageAgentCoreRuntimeAssets(bundle, destination);
  assert.deepEqual((await readdir(destination)).sort(), [
    "rg.exe",
    "ripgrep-LICENSE-MIT",
  ]);
  await writeFile(path.join(destination, "rg.exe"), "tampered");
  await assert.rejects(
    verifyAgentCoreRuntimeAssets(bundle, destination),
    /checksum mismatch/,
  );
  await stageAgentCoreRuntimeAssets(bundle, destination);
  await rm(path.join(destination, "ripgrep-LICENSE-MIT"));
  await assert.rejects(
    verifyAgentCoreRuntimeAssets(bundle, destination),
    /ENOENT/,
  );
  await writeFile(
    path.join(candidate.root, "bin/rg.exe"),
    "source changed after verification",
  );
  await assert.rejects(
    stageAgentCoreRuntimeAssets(bundle, destination),
    /checksum mismatch/,
  );
});

test("supports packaging the runtime license outside the executable directory", async (t) => {
  const candidate = await fixture(t);
  const bundle = await validateAgentCoreBundle(candidate.root, injectedChecks);
  const destination = await mkdtemp(
    path.join(tmpdir(), "metawork-runtime-layout-"),
  );
  t.after(() => rm(destination, { recursive: true, force: true }));
  const executableDirectory = path.join(destination, "bin");
  const licenseDirectory = path.join(destination, "resources", "licenses");
  const options = { licenseDirectory };

  await stageAgentCoreRuntimeAssets(bundle, executableDirectory, options);
  assert.deepEqual(await readdir(executableDirectory), ["rg.exe"]);
  assert.deepEqual(await readdir(licenseDirectory), ["ripgrep-LICENSE-MIT"]);
  await verifyAgentCoreRuntimeAssets(bundle, executableDirectory, options);
});

test("staged preflight refuses a retired revision lock", async (t) => {
  const candidate = await fixture(t);
  const root = await repository(t, candidate.manifest);
  await stageAgentCoreBundle({
    repositoryRoot: root,
    source: candidate.root,
    validationOptions: injectedChecks,
  });
  candidate.manifest.contract.binary_abi_revision = 14;
  await writeFile(
    path.join(
      root,
      "build_support",
      "agentcore-bundle.windows-x86_64.lock.json",
    ),
    JSON.stringify(candidate.manifest),
  );
  await assert.rejects(
    verifyStagedAgentCoreBundle(root, injectedVerification),
    /requires a revision 18 repository lock/,
  );
});

test("rejects a self-consistent bundle that differs from the repository lock", async (t) => {
  const { root, manifest } = await fixture(t);
  const expectedManifest = structuredClone(manifest);
  expectedManifest.version = "0.1.0-another-build";
  await assert.rejects(
    validateAgentCoreBundle(root, { ...injectedChecks, expectedManifest }),
    /repository lock/,
  );
});

test("rejects a missing or legacy binary ABI revision", async (t) => {
  const missing = await fixture(t, (manifest) => {
    delete manifest.contract.binary_abi_revision;
  });
  await assert.rejects(
    validateAgentCoreBundle(missing.root, injectedChecks),
    /contract fields do not match/,
  );

  const unsupported = await fixture(t, (manifest) => {
    manifest.contract.binary_abi_revision = 14;
  });
  await assert.rejects(
    validateAgentCoreBundle(unsupported.root, injectedChecks),
    /binary ABI revision/,
  );
});

test("rejects incorrect ABI table size and legacy contract fields", async (t) => {
  const table = await fixture(t, (manifest) => {
    manifest.contract.binary_abi_table_size = 136;
  });
  await assert.rejects(
    validateAgentCoreBundle(table.root, injectedChecks),
    /binary ABI table size/,
  );

  const legacy = await fixture(t, (manifest) => {
    manifest.contract.capabilities = 0x3ffffff;
  });
  await assert.rejects(
    validateAgentCoreBundle(legacy.root, injectedChecks),
    /contract fields do not match/,
  );
});

test("rejects missing and extra payload entries", async (t) => {
  const missing = await fixture(t, (manifest) => {
    manifest.files = manifest.files.filter(
      (file) => file.path !== "include/metask/agentcore.h",
    );
  });
  await assert.rejects(
    validateAgentCoreBundle(missing.root, injectedChecks),
    /filesystem contains missing or unknown entries/,
  );

  const extra = await fixture(t);
  await writeFile(path.join(extra.root, "stale.txt"), "stale");
  await assert.rejects(
    validateAgentCoreBundle(extra.root, injectedChecks),
    /filesystem contains missing or unknown entries/,
  );
});

test("rejects a bundle for another target", async (t) => {
  const { root } = await fixture(t);
  await assert.rejects(
    validateAgentCoreBundle(root, {
      ...injectedChecks,
      platform: "linux",
    }),
    /unsupported AgentCore host target/,
  );
});

test("rejects dirty provenance and versions that do not match source identity", async (t) => {
  const dirty = await fixture(t, (manifest) => {
    manifest.source.dirty = true;
    manifest.version = "0.1.0-dev+0123456789ab.dirty";
  });
  await assert.rejects(
    validateAgentCoreBundle(dirty.root, injectedChecks),
    /must come from a clean source checkout/,
  );

  const mismatched = await fixture(t, (manifest) => {
    manifest.version = "0.1.0-dev+0123456789ab.dirty";
  });
  await assert.rejects(
    validateAgentCoreBundle(mismatched.root, injectedChecks),
    /version does not match source identity/,
  );
});

test("rejects the revision 2 manifest layout", async (t) => {
  const oldSource = await fixture(t, (manifest) => {
    manifest.source.dirty_source_sha256 = "";
  });
  await assert.rejects(
    validateAgentCoreBundle(oldSource.root, injectedChecks),
    /source fields do not match/,
  );

  const oldBuild = await fixture(t, (manifest) => {
    manifest.build.resolved_target = manifest.target.zig_target;
  });
  await assert.rejects(
    validateAgentCoreBundle(oldBuild.root, injectedChecks),
    /build fields do not match/,
  );
});

test("rejects object-shaped, duplicate, and case-colliding file lists", async (t) => {
  const objectFiles = await fixture(t, (manifest) => {
    manifest.files = Object.fromEntries(
      manifest.files.map(({ path: relativePath, sha256 }) => [
        relativePath,
        { sha256 },
      ]),
    );
  });
  await assert.rejects(
    validateAgentCoreBundle(objectFiles.root, injectedChecks),
    /files must be an array/,
  );

  const duplicate = await fixture(t, (manifest) => {
    manifest.files.push(structuredClone(manifest.files[0]));
  });
  await assert.rejects(
    validateAgentCoreBundle(duplicate.root, injectedChecks),
    /duplicate payload path/,
  );

  const collision = await fixture(t, (manifest) => {
    const copy = structuredClone(manifest.files[0]);
    copy.path = copy.path.toUpperCase();
    manifest.files.push(copy);
  });
  await assert.rejects(
    validateAgentCoreBundle(collision.root, injectedChecks),
    /case-colliding payload path/,
  );
});

test("rejects unsafe manifest payload paths", async (t) => {
  for (const unsafePath of [
    "../escape",
    "/absolute",
    "bindings\\zig\\root.zig",
    "bindings/zig/røot.zig",
    ".",
  ]) {
    const candidate = await fixture(t, (manifest) => {
      manifest.files[0].path = unsafePath;
    });
    await assert.rejects(
      validateAgentCoreBundle(candidate.root, injectedChecks),
      /normalized relative file path|unsafe separator|unsupported path characters/,
    );
  }
});

test("rejects manifest bytes that differ from the exact repository lock", async (t) => {
  const { root, manifest } = await fixture(t);
  const lockBytes = await readFile(path.join(root, "manifest.json"), "utf8");
  await writeFile(
    path.join(root, "manifest.json"),
    lockBytes.replace(
      '"vendor":"metask"',
      '"vendor":"ignored","vendor":"metask"',
    ),
  );
  await assert.rejects(
    validateAgentCoreBundle(root, {
      ...injectedChecks,
      expectedManifest: manifest,
      expectedManifestBytes: lockBytes,
    }),
    /manifest bytes do not match/,
  );
});

test("rejects payload and root symbolic links", async (t) => {
  const payloadLink = await fixture(t);
  const libraryPath = path.join(payloadLink.root, fixtureFiles[0]);
  await rm(libraryPath);
  try {
    await symlink("../README.md", libraryPath);
  } catch (error) {
    if (error?.code === "EPERM") {
      t.skip("Windows symlink creation requires Developer Mode or elevation");
      return;
    }
    throw error;
  }
  await assert.rejects(
    validateAgentCoreBundle(payloadLink.root, injectedChecks),
    /symbolic link/,
  );

  const rootLinkTarget = await fixture(t);
  const rootLink = `${rootLinkTarget.root}-link`;
  t.after(() => rm(rootLink, { force: true }));
  await symlink(rootLinkTarget.root, rootLink);
  await assert.rejects(
    validateAgentCoreBundle(rootLink, injectedChecks),
    /root must not be a symbolic link/,
  );
});

test("rejects missing, duplicated, and obsolete discovery symbols", async (t) => {
  const { root } = await fixture(t);
  await assert.rejects(
    validateAgentCoreBundle(root, { ...injectedChecks, symbols: "" }),
    /exactly one pinned discovery symbol/,
  );
  await assert.rejects(
    validateAgentCoreBundle(root, {
      ...injectedChecks,
      symbols: "T _metask_agentcore_get_api\nT _metask_agentcore_get_api\n",
    }),
    /exactly one pinned discovery symbol/,
  );
  await assert.rejects(
    validateAgentCoreBundle(root, {
      ...injectedChecks,
      symbols: "T _metask_agentcore_get_api\nT _metacodes_agentcore_get_api\n",
    }),
    /obsolete revision 2 discovery symbol/,
  );
});

test("stages and verifies only the locked manifest payload", async (t) => {
  const { root: source, manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  const result = await stageAgentCoreBundle({
    repositoryRoot,
    source,
    validationOptions: injectedChecks,
  });
  assert.equal(
    result.target,
    path.join(repositoryRoot, ".agentcore", "bundles", "x86_64-windows-gnu"),
  );
  assert.deepEqual(
    JSON.parse(await readFile(path.join(result.target, "manifest.json"))),
    manifest,
  );
  const verified = await verifyStagedAgentCoreBundle(
    repositoryRoot,
    injectedVerification,
  );
  assert.equal(verified.manifest.version, manifest.version);
  assert.deepEqual(await readdir(path.join(repositoryRoot, ".agentcore")), [
    "bundles",
  ]);
  assert.deepEqual(
    await readdir(path.join(repositoryRoot, ".agentcore", "bundles")),
    ["x86_64-windows-gnu"],
  );
});

test("stages macOS arm64 and x64 bundles without replacing either target", async (t) => {
  const arm64 = await macosFixture(t, "aarch64-macos");
  const x64 = await macosFixture(t, "x86_64-macos");
  const repositoryRoot = await repository(t, arm64.manifest);
  await writeFile(
    path.join(
      repositoryRoot,
      "build_support",
      "agentcore-bundle.macos-x86_64.lock.json",
    ),
    JSON.stringify(x64.manifest),
  );
  const validationOptions = {
    platform: "darwin",
    architecture: "arm64",
    zigVersion: "0.16.0",
    symbols: "00000000 T metask_agentcore_get_api\n",
  };

  await stageAgentCoreBundle({
    repositoryRoot,
    source: arm64.root,
    validationOptions,
  });
  await stageAgentCoreBundle({
    repositoryRoot,
    source: x64.root,
    validationOptions,
  });

  assert.deepEqual(
    (await readdir(path.join(repositoryRoot, ".agentcore", "bundles"))).sort(),
    ["aarch64-macos", "x86_64-macos"],
  );
  await verifyStagedAgentCoreBundle(repositoryRoot, {
    targetId: "aarch64-macos",
    validationOptions,
  });
  await verifyStagedAgentCoreBundle(repositoryRoot, {
    targetId: "x86_64-macos",
    validationOptions,
  });
});

test("copy failure preserves the canonical bundle", async (t) => {
  const { root: source, manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  const { storageRoot, target } = await seedCanonicalBundle(repositoryRoot);

  await assert.rejects(
    stageAgentCoreBundle({
      repositoryRoot,
      source,
      validationOptions: injectedChecks,
      fileOperations: injectedFileOperations({
        copyFile: async () => {
          throw new Error("injected copy failure");
        },
      }),
    }),
    /injected copy failure/,
  );
  assert.equal(
    await readFile(path.join(target, "old"), "utf8"),
    "old-canonical",
  );
  assert.deepEqual(await readdir(storageRoot), ["x86_64-windows-gnu"]);
});

test("target rename failure preserves the canonical bundle", async (t) => {
  const { root: source, manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  const { storageRoot, target } = await seedCanonicalBundle(repositoryRoot);

  await assert.rejects(
    stageAgentCoreBundle({
      repositoryRoot,
      source,
      validationOptions: injectedChecks,
      fileOperations: injectedFileOperations({
        rename: async (from, to) => {
          if (from === target)
            throw new Error("injected target rename failure");
          await rename(from, to);
        },
      }),
    }),
    /injected target rename failure/,
  );
  assert.equal(
    await readFile(path.join(target, "old"), "utf8"),
    "old-canonical",
  );
  assert.deepEqual(await readdir(storageRoot), ["x86_64-windows-gnu"]);
});

test("install rename failure restores the previous canonical bundle", async (t) => {
  const { root: source, manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  const { storageRoot, target } = await seedCanonicalBundle(repositoryRoot);

  await assert.rejects(
    stageAgentCoreBundle({
      repositoryRoot,
      source,
      validationOptions: injectedChecks,
      fileOperations: injectedFileOperations({
        rename: async (from, to) => {
          if (
            path.basename(from).startsWith(".x86_64-windows-gnu-staging-") &&
            to === target
          )
            throw new Error("injected install rename failure");
          await rename(from, to);
        },
      }),
    }),
    /injected install rename failure/,
  );
  assert.equal(
    await readFile(path.join(target, "old"), "utf8"),
    "old-canonical",
  );
  assert.deepEqual(await readdir(storageRoot), ["x86_64-windows-gnu"]);
});

test("failed install and restore leave one recoverable backup", async (t) => {
  const { root: source, manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  const { storageRoot, target } = await seedCanonicalBundle(repositoryRoot);

  await assert.rejects(
    stageAgentCoreBundle({
      repositoryRoot,
      source,
      validationOptions: injectedChecks,
      fileOperations: injectedFileOperations({
        rename: async (from, to) => {
          if (to === target && from !== target)
            throw new Error("injected destination failure");
          await rename(from, to);
        },
      }),
    }),
    /install and canonical restore both failed/,
  );
  const residues = await readdir(storageRoot);
  assert.equal(residues.length, 1);
  assert.match(residues[0], /^\.x86_64-windows-gnu-backup-/);

  await stageAgentCoreBundle({
    repositoryRoot,
    source,
    validationOptions: injectedChecks,
  });
  assert.deepEqual(await readdir(storageRoot), ["x86_64-windows-gnu"]);
  await verifyStagedAgentCoreBundle(repositoryRoot, injectedVerification);
});

test("backup cleanup failure reports installed state and is recovered next run", async (t) => {
  const { root: source, manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  const { storageRoot } = await seedCanonicalBundle(repositoryRoot);
  let injected = false;

  await assert.rejects(
    stageAgentCoreBundle({
      repositoryRoot,
      source,
      validationOptions: injectedChecks,
      fileOperations: injectedFileOperations({
        rm: async (target, options) => {
          if (
            !injected &&
            path.basename(target).startsWith(".x86_64-windows-gnu-backup-")
          ) {
            injected = true;
            throw new Error("injected backup cleanup failure");
          }
          await rm(target, options);
        },
      }),
    }),
    /installed but backup cleanup failed/,
  );
  await verifyStagedAgentCoreBundle(repositoryRoot, injectedVerification);
  assert.equal(
    (await readdir(storageRoot)).filter((entry) =>
      entry.startsWith(".x86_64-windows-gnu-backup-"),
    ).length,
    1,
  );

  await stageAgentCoreBundle({
    repositoryRoot,
    source,
    validationOptions: injectedChecks,
  });
  assert.deepEqual(await readdir(storageRoot), ["x86_64-windows-gnu"]);
});

test("cleans stale staging and backup residues when canonical exists", async (t) => {
  const { root: source, manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  const storageRoot = path.join(repositoryRoot, ".agentcore", "bundles");
  for (const relativePath of [
    "x86_64-windows-gnu/old",
    ".x86_64-windows-gnu-staging-stale/junk",
    ".x86_64-windows-gnu-backup-stale/old",
  ]) {
    await mkdir(path.dirname(path.join(storageRoot, relativePath)), {
      recursive: true,
    });
    await writeFile(path.join(storageRoot, relativePath), "old");
  }

  await stageAgentCoreBundle({
    repositoryRoot,
    source,
    validationOptions: injectedChecks,
  });
  assert.deepEqual(await readdir(storageRoot), ["x86_64-windows-gnu"]);
});

test("recovers one backup before staging and rejects ambiguous backups", async (t) => {
  const single = await fixture(t);
  const singleRepository = await repository(t, single.manifest);
  const singleStorage = path.join(singleRepository, ".agentcore", "bundles");
  await mkdir(path.join(singleStorage, ".x86_64-windows-gnu-backup-one"), {
    recursive: true,
  });
  await writeFile(
    path.join(singleStorage, ".x86_64-windows-gnu-backup-one", "old"),
    "old",
  );
  await stageAgentCoreBundle({
    repositoryRoot: singleRepository,
    source: single.root,
    validationOptions: injectedChecks,
  });
  assert.deepEqual(await readdir(singleStorage), ["x86_64-windows-gnu"]);

  const multiple = await fixture(t);
  const multipleRepository = await repository(t, multiple.manifest);
  const multipleStorage = path.join(
    multipleRepository,
    ".agentcore",
    "bundles",
  );
  await mkdir(path.join(multipleStorage, ".x86_64-windows-gnu-backup-one"), {
    recursive: true,
  });
  await mkdir(path.join(multipleStorage, ".x86_64-windows-gnu-backup-two"), {
    recursive: true,
  });
  await assert.rejects(
    stageAgentCoreBundle({
      repositoryRoot: multipleRepository,
      source: multiple.root,
      validationOptions: injectedChecks,
    }),
    /multiple AgentCore backup residues/,
  );
});

test("verify-staged reports a missing canonical bundle", async (t) => {
  const { manifest } = await fixture(t);
  const repositoryRoot = await repository(t, manifest);
  await assert.rejects(
    verifyStagedAgentCoreBundle(repositoryRoot, injectedVerification),
    /staged AgentCore bundle x86_64-windows-gnu is missing/,
  );
});

test("requires the exact shared library declaration and both pinned libraries", async (t) => {
  for (const mutate of [
    (m) => {
      delete m.shared_library;
    },
    (m) => {
      m.shared_library.extra = true;
    },
    (m) => {
      m.shared_library.entry_point = "other_entry";
    },
    (m) => {
      m.shared_library.path = "lib/other.dll";
    },
    (m) => {
      m.shared_library.install_name = "other";
    },
    (m) => {
      m.shared_library.needed = [null];
    },
    (m) => {
      m.shared_library.needed.push(m.shared_library.needed[0]);
    },
    (m) => {
      m.files = m.files.filter((f) => f.path !== "lib/metask_agentcore.dll");
    },
    (m) => {
      m.files = m.files.filter((f) => f.path !== "lib/metask_agentcore.lib");
    },
  ]) {
    const candidate = await fixture(t, mutate);
    await assert.rejects(
      validateAgentCoreBundle(candidate.root, injectedChecks),
      /manifest|shared library|shared_library|checksum-pinned/,
    );
  }
  const missing = await fixture(t);
  await rm(path.join(missing.root, "lib/metask_agentcore.dll"));
  await assert.rejects(
    validateAgentCoreBundle(missing.root, injectedChecks),
    /filesystem contains missing/,
  );
  const tampered = await fixture(t);
  await writeFile(
    path.join(tampered.root, "lib/metask_agentcore.dll"),
    "tampered",
  );
  await assert.rejects(
    validateAgentCoreBundle(tampered.root, injectedChecks),
    /checksum mismatch/,
  );
});
