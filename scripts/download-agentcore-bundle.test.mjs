import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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
      await downloadAgentCoreArchive(lock, target, fetchResponse),
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
      downloadAgentCoreArchive(lock, "aarch64-macos", fetchResponse),
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
      downloadAgentCoreArchive(lock, "aarch64-macos", fetchResponse),
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
    downloadAgentCoreArchive(lock, "aarch64-macos", fetchResponse),
    /archive length mismatch/,
  );

  const corrupted = Buffer.from(bytes);
  corrupted[0] ^= 1;
  responses.set(`${origin}${name}`, corrupted);
  await assert.rejects(
    downloadAgentCoreArchive(lock, "aarch64-macos", fetchResponse),
    /archive SHA-256 mismatch/,
  );
});
