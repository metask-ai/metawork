import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { verifyPinnedDownload } from "./check-office-public-sources.mjs";

const body = Buffer.from("fixed vendor artifact");
const pin = {
  name: "fixture",
  url: "https://example.invalid/vendor.zip",
  algorithm: "sha256",
  digest: createHash("sha256").update(body).digest("hex"),
  bytes: body.length,
};

test("public source qualification verifies actual GET bytes without trusting HEAD length", async () => {
  const result = await verifyPinnedDownload(pin, async (url, options) => {
    assert.equal(url, pin.url);
    assert.equal(options.redirect, "error");
    assert.equal(options.headers["Accept-Encoding"], "identity");
    assert.equal(options.method, undefined); // fetch defaults to GET
    return new Response(body, { headers: { "content-length": "1" } });
  });
  assert.equal(result.bytes, body.length);
  assert.equal(result.verified, true);
});

test("public source qualification rejects corruption, truncation, and surplus bytes", async () => {
  for (const bytes of [
    Buffer.from("different artifact"),
    body.subarray(1),
    Buffer.concat([body, body]),
  ])
    await assert.rejects(
      verifyPinnedDownload(pin, async () => new Response(bytes)),
      /Office public source/u,
    );
});

test("public source qualification rejects redirects and partial responses", async () => {
  for (const status of [206, 302, 404])
    await assert.rejects(
      verifyPinnedDownload(pin, async () => new Response(body, { status })),
      /direct complete body/u,
    );
  await assert.rejects(
    verifyPinnedDownload(pin, async () => ({
      status: 200,
      redirected: true,
      body: new Response(body).body,
    })),
    /direct complete body/u,
  );
});

test("public source qualification refuses unpinned or credential-bearing sources before network", async () => {
  let requests = 0;
  for (const change of [
    { url: "http://example.invalid/file" },
    { url: "https://secret@example.invalid/file" },
    { url: "https://example.invalid/file?latest" },
    { digest: "bad" },
    { algorithm: "sha1" },
    { bytes: -1 },
  ])
    await assert.rejects(
      verifyPinnedDownload({ ...pin, ...change }, async () => {
        requests++;
      }),
      /Invalid pinned/u,
    );
  assert.equal(requests, 0);
});

test("public registry source qualification supports the root lock SHA512 identity", async () => {
  const result = await verifyPinnedDownload(
    {
      ...pin,
      algorithm: "sha512",
      bytes: null,
      digest: createHash("sha512").update(body).digest("hex"),
    },
    async () => new Response(body),
  );
  assert.equal(result.bytes, body.length);
});

const archivePin = {
  ...pin,
  url: "https://downloadarchive.documentfoundation.org/libreoffice/old/1/file.msi",
};
test("official archive accepts at most three HTTPS hops and still hashes the final body", async () => {
  for (const final of [body, Buffer.from("wrong same-sized bytes")]) {
    let calls = 0;
    const result = verifyPinnedDownload(archivePin, async (_url, options) => {
      assert.equal(options.redirect, "manual");
      if (calls++ < 3)
        return new Response(null, {
          status: 302,
          headers: { location: `https://mirror.example.org/${calls}.msi` },
        });
      return new Response(final);
    });
    if (final === body) assert.equal((await result).verified, true);
    else await assert.rejects(result, /Office public source/u);
    assert.equal(calls, 4);
  }
  let calls = 0;
  await assert.rejects(
    verifyPinnedDownload(archivePin, async () => {
      calls++;
      return new Response(null, {
        status: 302,
        headers: { location: "https://mirror.example.org/file.msi" },
      });
    }),
    /direct complete body/u,
  );
  assert.equal(calls, 4);
});

test("official archive refuses credentials, parameters and HTTPS downgrade at each hop", async () => {
  for (const location of [
    "http://mirror.example.org/file",
    "https://key@mirror.example.org/file",
    "https://mirror.example.org/file?q=1",
    "https://mirror.example.org/file#fragment",
  ]) {
    let calls = 0;
    await assert.rejects(
      verifyPinnedDownload(archivePin, async () => {
        calls++;
        return new Response(null, { status: 302, headers: { location } });
      }),
      /Invalid pinned/u,
    );
    assert.equal(calls, 1);
  }
});
