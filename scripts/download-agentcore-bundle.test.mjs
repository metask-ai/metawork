import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { downloadAgentCoreArchive } from "./download-agentcore-bundle.mjs";

const lock = {
  version: "1.2.3",
  source: { commit: "a".repeat(40) },
  contract: { binary_abi_version: 1, binary_abi_revision: 26 },
};
const origin = "https://downloads.metask-ai.com/agentcore/v1.2.3/";
const archives = {
  "x86_64-windows-msvc": ["core-win.zip", Buffer.from("windows bundle")],
  "aarch64-macos": ["core-mac.tar.gz", Buffer.from("macos bundle")],
};

function fixture() {
  const release = {
    schema_version: 1,
    version: lock.version,
    source_commit: lock.source.commit,
    binary_abi: { version: 1, revision: 26 },
    targets: {},
  };
  const responses = new Map();
  const requests = [];
  for (const [target, [name, bytes]] of Object.entries(archives)) {
    release.targets[name] = {
      length: bytes.length,
      hashes: { sha256: createHash("sha256").update(bytes).digest("hex") },
      custom: { target },
    };
    responses.set(`${origin}${name}`, bytes);
  }
  async function fetchResponse(url, options) {
    assert.equal(options.redirect, "error");
    requests.push(url.href);
    if (url.href === `${origin}manifest.json`) return Response.json(release);
    assert.ok(responses.has(url.href), `unexpected download: ${url.href}`);
    return new Response(responses.get(url.href));
  }
  return { release, responses, requests, fetchResponse };
}

for (const [target, [name, bytes]] of Object.entries(archives)) {
  test(`downloads only the archive declared for ${target}`, async () => {
    const { fetchResponse, requests } = fixture();
    assert.deepEqual(
      await downloadAgentCoreArchive(lock, target, { fetchResponse }),
      bytes,
    );
    assert.deepEqual(requests, [`${origin}manifest.json`, `${origin}${name}`]);
  });
}

test("rejects release identity mismatches before requesting the archive", async () => {
  for (const changes of [
    { version: "1.2.4" },
    { source_commit: "b".repeat(40) },
    { binary_abi: { version: 1, revision: 25 } },
  ]) {
    const { release, fetchResponse, requests } = fixture();
    Object.assign(release, changes);
    await assert.rejects(
      downloadAgentCoreArchive(lock, "aarch64-macos", { fetchResponse }),
      /release manifest does not match/,
    );
    assert.deepEqual(requests, [`${origin}manifest.json`]);
  }
});

test("rejects missing, ambiguous, and escaping archive entries", async () => {
  for (const [path, error] of [
    [null, /exactly one/],
    ["duplicate.tar.gz", /exactly one/],
    ["../escaped.tar.gz", /Invalid AgentCore archive metadata/],
  ]) {
    const { release, fetchResponse, requests } = fixture();
    const archive = release.targets["core-mac.tar.gz"];
    if (path !== "duplicate.tar.gz") delete release.targets["core-mac.tar.gz"];
    if (path !== null) release.targets[path] = archive;
    await assert.rejects(
      downloadAgentCoreArchive(lock, "aarch64-macos", { fetchResponse }),
      error,
    );
    assert.deepEqual(requests, [`${origin}manifest.json`]);
  }
});

test("rejects truncated and same-length corrupted archives", async () => {
  const [name, bytes] = archives["aarch64-macos"];
  const { responses, fetchResponse } = fixture();
  responses.set(`${origin}${name}`, bytes.subarray(1));
  await assert.rejects(
    downloadAgentCoreArchive(lock, "aarch64-macos", { fetchResponse }),
    /archive length mismatch/,
  );

  const corrupted = Buffer.from(bytes);
  corrupted[0] ^= 1;
  responses.set(`${origin}${name}`, corrupted);
  await assert.rejects(
    downloadAgentCoreArchive(lock, "aarch64-macos", { fetchResponse }),
    /archive SHA-256 mismatch/,
  );
});

test("uses an exact cached release offline and rejects corrupted cache contents", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-cache-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cacheDir = path.join(root, "cache");
  const target = "aarch64-macos";
  const [, bytes] = archives[target];
  const { fetchResponse } = fixture();
  await downloadAgentCoreArchive(lock, target, { cacheDir, fetchResponse });

  const offline = {
    cacheDir,
    fetchResponse: () => assert.fail("cache hit attempted a network request"),
  };
  assert.deepEqual(
    await downloadAgentCoreArchive(lock, target, offline),
    bytes,
  );

  const archiveFile = path.join(cacheDir, "bundle.archive");
  const corrupted = Buffer.from(bytes);
  corrupted[0] ^= 1;
  await writeFile(archiveFile, corrupted);
  await assert.rejects(
    downloadAgentCoreArchive(lock, target, offline),
    /archive SHA-256 mismatch/,
  );
  await writeFile(archiveFile, bytes);
  const manifestFile = path.join(cacheDir, "manifest.json");
  const release = JSON.parse(await readFile(manifestFile, "utf8"));
  release.source_commit = "b".repeat(40);
  await writeFile(manifestFile, JSON.stringify(release));
  await assert.rejects(
    downloadAgentCoreArchive(lock, target, offline),
    /release manifest does not match/,
  );
});

test("allows one retry total for a transient error while fetching a release", async () => {
  const target = "aarch64-macos";
  const [name, bytes] = archives[target];
  const transient = new TypeError("fetch failed", {
    cause: { code: "UND_ERR_CONNECT_TIMEOUT" },
  });
  for (const failAgain of [false, true]) {
    const { fetchResponse } = fixture();
    const requests = [];
    const download = downloadAgentCoreArchive(lock, target, {
      fetchResponse: (url, options) => {
        requests.push(url.href);
        if (requests.length === 1 || (failAgain && requests.length === 3))
          throw transient;
        return fetchResponse(url, options);
      },
    });
    if (failAgain) await assert.rejects(download, /AgentCore download failed/);
    else assert.deepEqual(await download, bytes);
    assert.deepEqual(requests, [
      `${origin}manifest.json`,
      `${origin}manifest.json`,
      `${origin}${name}`,
    ]);
  }
});

test("does not retry a permanent HTTP failure", async () => {
  let requests = 0;
  await assert.rejects(
    downloadAgentCoreArchive(lock, "aarch64-macos", {
      fetchResponse: () => {
        requests += 1;
        return new Response(null, { status: 404 });
      },
    }),
    /HTTP 404/,
  );
  assert.equal(requests, 1);
});

test("retries HTTP 429 and 5xx using the same budget as network errors", async () => {
  const target = "aarch64-macos";
  const [name, bytes] = archives[target];
  for (const status of [429, 503]) {
    const { fetchResponse } = fixture();
    const requests = [];
    assert.deepEqual(
      await downloadAgentCoreArchive(lock, target, {
        fetchResponse: (url, options) => {
          requests.push(url.href);
          if (requests.length === 2) return new Response("busy", { status });
          return fetchResponse(url, options);
        },
      }),
      bytes,
    );
    assert.deepEqual(requests, [
      `${origin}manifest.json`,
      `${origin}${name}`,
      `${origin}${name}`,
    ]);
  }

  const { fetchResponse } = fixture();
  const requests = [];
  await assert.rejects(
    downloadAgentCoreArchive(lock, target, {
      fetchResponse: (url, options) => {
        requests.push(url.href);
        if (requests.length === 1) return new Response(null, { status: 429 });
        if (requests.length === 3) {
          throw new TypeError("fetch failed", {
            cause: { code: "UND_ERR_CONNECT_TIMEOUT" },
          });
        }
        return fetchResponse(url, options);
      },
    }),
    /AgentCore download failed/,
  );
  assert.deepEqual(requests, [
    `${origin}manifest.json`,
    `${origin}manifest.json`,
    `${origin}${name}`,
  ]);
});

test("publishes both cache files even when a previous write was interrupted", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-cache-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cacheDir = path.join(root, "cache");
  const interrupted = await mkdtemp(`${cacheDir}.tmp-`);
  await writeFile(path.join(interrupted, "manifest.json"), "incomplete");
  const target = "aarch64-macos";
  const { fetchResponse } = fixture();

  await downloadAgentCoreArchive(lock, target, { cacheDir, fetchResponse });

  assert.deepEqual((await readdir(cacheDir)).sort(), [
    "bundle.archive",
    "manifest.json",
  ]);
  assert.deepEqual((await readdir(root)).sort(), [
    "cache",
    path.basename(interrupted),
  ]);
});

test("failed cache publication preserves the existing destination", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-cache-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cacheDir = path.join(root, "cache");
  const target = "aarch64-macos";
  const { fetchResponse } = fixture();

  await assert.rejects(
    downloadAgentCoreArchive(lock, target, {
      cacheDir,
      fetchResponse: async (url, options) => {
        if (url.href === `${origin}${archives[target][0]}`) {
          await mkdir(cacheDir);
          await writeFile(path.join(cacheDir, "sentinel"), "existing");
        }
        return fetchResponse(url, options);
      },
    }),
    { syscall: "rename" },
  );
  assert.deepEqual(await readdir(root), ["cache"]);
  assert.deepEqual(await readdir(cacheDir), ["sentinel"]);
});
