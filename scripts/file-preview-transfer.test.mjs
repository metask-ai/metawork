import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import {
  decodeFilePreview,
  decodeWorkspaceDirectory,
} from "../frontend/src/bridge/decode-contracts.ts";
import { FilePreviewLoader } from "../frontend/src/bridge/file-preview.ts";
import { commands } from "../frontend/src/bridge/commands.ts";

const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8k8AAAAASUVORK5CYII=",
  "base64",
);
const empty = { content: "", truncated: false, redacted: false };

test("generated MP4 shares file preview admission and revokes its source on security change", async () => {
  const fixture = JSON.parse(
    await readFile(
      new URL("../src/bridge/file_preview_video.fixture", import.meta.url),
      "utf8",
    ),
  );
  const bytes = await readFile(
    new URL("../tests/fixtures/generated-video.mp4", import.meta.url),
  );
  assert.equal(decodeFilePreview(fixture).video.sizeBytes, bytes.length);
  assert.throws(() => decodeFilePreview({ ...fixture, image: {} }));
  assert.throws(() => decodeFilePreview({ ...fixture, state: "restricted" }));
  assert.throws(() =>
    decodeFilePreview({
      ...fixture,
      video: { ...fixture.video, sizeBytes: "67108865" },
    }),
  );
  const calls = [];
  const fileReferenceId = "file-3-1-1-1";
  const loader = new FilePreviewLoader(
    async (command, payload) => {
      calls.push({ command, payload });
      switch (command) {
        case commands.previewFile:
          return fixture;
        case commands.readPreviewVideo:
          return {
            state: "ready",
            token: fixture.video.token,
            offset: "0",
            bytes: String(bytes.length),
            dataBase64: bytes.toString("base64"),
          };
        case commands.releasePreview:
          return { ...payload, released: true };
        default:
          assert.fail(command);
      }
    },
    () => "1",
  );
  const result = await loader.load("3", "7", fileReferenceId);
  assert.equal(result.state, "ready");
  assert.deepEqual(
    calls.map((call) => call.command),
    [commands.previewFile, commands.readPreviewVideo, commands.releasePreview],
  );
  assert.deepEqual(calls[0].payload, {
    generation: "1",
    previewId: "1",
    taskId: "3",
    runId: "7",
    fileReferenceId,
  });
  const src = result.video.src;
  const media = await fetch(src);
  assert.equal(media.headers.get("content-type"), "video/mp4");
  assert.deepEqual(Buffer.from(await media.arrayBuffer()), bytes);
  const second = await loader.load("3", "8", "file-3-2-1-1");
  assert.equal(second.state, "ready");
  assert.equal(result.video.valid(), true);
  const secondSrc = second.video.src;
  loader.observeSecurityEpoch("2");
  assert.equal(result.video.valid(), false);
  assert.equal(second.video.valid(), false);
  await assert.rejects(fetch(src));
  await assert.rejects(fetch(secondSrc));
});

function deferred() {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
class Host {
  bytes = png;
  epoch = "1";
  width = 1;
  height = 1;
  active = new Map();
  cancelled = new Set();
  calls = [];
  busy = 0;
  onRead;
  loader = new FilePreviewLoader(
    (command, payload) => this.invoke(command, payload),
    () => "1",
  );
  async invoke(command, payload) {
    this.calls.push({ command, payload });
    if (command === commands.previewFile) {
      if (this.cancelled.has(payload.previewId))
        return { ...empty, state: "error" };
      if (payload.fileReferenceId === "text")
        return { ...empty, state: "ready", content: "text is available" };
      if (this.busy > 0) {
        this.busy--;
        return { ...empty, state: "busy" };
      }
      const token = BigInt(payload.previewId).toString(16).padStart(48, "0");
      this.active.set(payload.previewId, { bytes: this.bytes, token });
      return {
        ...empty,
        state: "ready",
        image: {
          token,
          mediaType: "image/png",
          sizeBytes: String(this.bytes.length),
          width: this.width,
          height: this.height,
          chunkBytes: "262143",
          securityEpoch: this.epoch,
        },
      };
    }
    if (command === commands.readPreviewImage) {
      const override = await this.onRead?.(payload);
      if (override) return override;
      const resource = this.active.get(payload.previewId);
      assert.ok(resource, "read only within an owned transfer");
      const offset = Number(payload.offset);
      const bytes = resource.bytes.subarray(offset, offset + 262143);
      return {
        state: "ready",
        token: resource.token,
        offset: payload.offset,
        bytes: String(bytes.length),
        dataBase64: bytes.toString("base64"),
      };
    }
    assert.equal(command, commands.releasePreview);
    this.cancelled.add(payload.previewId);
    this.active.delete(payload.previewId);
    return {
      generation: payload.generation,
      previewId: payload.previewId,
      released: true,
    };
  }
  load(reference = "image", options) {
    return this.loader.load("17", "23", reference, options);
  }
}

test("workspace directories use the native fixture and reject unsafe or non-ready entries", async () => {
  const fixture = JSON.parse(
    await readFile(
      new URL("../src/bridge/workspace_directory.fixture", import.meta.url),
      "utf8",
    ),
  );
  assert.deepEqual(decodeWorkspaceDirectory(fixture), fixture);
  for (const name of [
    "../outside",
    "/root",
    "C:\\file",
    "a/b",
    "file:stream",
    "..",
    ".",
    "a\u0000b",
  ])
    assert.throws(() =>
      decodeWorkspaceDirectory({
        ...fixture,
        entries: [{ name, kind: "file" }],
      }),
    );
  assert.throws(() =>
    decodeWorkspaceDirectory({ ...fixture, state: "restricted" }),
  );
  assert.throws(() =>
    decodeWorkspaceDirectory({
      ...fixture,
      entries: [fixture.entries[0], fixture.entries[0]],
    }),
  );
});

test("workspace preview and directory reads share request IDs and preserve their exact authority", async () => {
  const calls = [];
  const loader = new FilePreviewLoader(
    async (command, payload) => {
      calls.push({ command, payload });
      if (command === commands.listDirectory)
        return {
          state: "ready",
          entries: [],
          truncated: false,
          redacted: false,
        };
      if (command === commands.releasePreview)
        return {
          generation: payload.generation,
          previewId: payload.previewId,
          released: true,
        };
      return { ...empty, state: "ready", content: "workspace file" };
    },
    () => "7",
  );
  await loader.listDirectory("17", "2", "3", "docs");
  const preview = await loader.loadWorkspace(
    "17",
    "2",
    "3",
    "docs/unreferenced.md",
  );
  assert.equal(preview.content, "workspace file");
  assert.deepEqual(
    calls.map((call) => call.command),
    [
      commands.listDirectory,
      commands.previewWorkspaceFile,
      commands.releasePreview,
    ],
  );
  assert.deepEqual(calls[0].payload, {
    generation: "7",
    previewId: "1",
    taskId: "17",
    workspaceId: "2",
    workspaceEpoch: "3",
    path: "docs",
  });
  assert.deepEqual(calls[1].payload, {
    generation: "7",
    previewId: "2",
    taskId: "17",
    workspaceId: "2",
    workspaceEpoch: "3",
    path: "docs/unreferenced.md",
  });
});

test("draft attachment previews submit only the grant token and reuse the image transfer", async () => {
  const calls = [];
  const grant = "c".repeat(48);
  const imageToken = "d".repeat(48);
  const loader = new FilePreviewLoader(
    async (command, payload) => {
      calls.push({ command, payload });
      if (command === commands.previewAttachment)
        return {
          ...empty,
          state: "ready",
          image: {
            token: imageToken,
            mediaType: "image/png",
            sizeBytes: String(png.length),
            width: 1,
            height: 1,
            chunkBytes: "262143",
            securityEpoch: "1",
          },
        };
      if (command === commands.readPreviewImage)
        return {
          state: "ready",
          token: imageToken,
          offset: payload.offset,
          bytes: String(png.length),
          dataBase64: png.toString("base64"),
        };
      assert.equal(command, commands.releasePreview);
      return {
        generation: payload.generation,
        previewId: payload.previewId,
        released: true,
      };
    },
    () => "7",
  );
  const preview = await loader.loadAttachment(grant);
  assert.equal(preview.state, "ready");
  assert.deepEqual(Buffer.from(preview.image.src.split(",")[1], "base64"), png);
  assert.deepEqual(
    calls.map((call) => call.command),
    [
      commands.previewAttachment,
      commands.readPreviewImage,
      commands.releasePreview,
    ],
  );
  assert.deepEqual(calls[0].payload, {
    generation: "7",
    previewId: "1",
    token: grant,
  });
  preview.release();
});

test("sent image previews address the Run input position, never a path or token", async () => {
  const calls = [];
  const loader = new FilePreviewLoader(
    async (command, payload) => {
      calls.push({ command, payload });
      if (command === commands.previewRunInputAttachment)
        return { ...empty, state: "missing" };
      assert.equal(command, commands.releasePreview);
      return {
        generation: payload.generation,
        previewId: payload.previewId,
        released: true,
      };
    },
    () => "7",
  );
  const preview = await loader.loadRunAttachment("17", "23", 1);
  assert.equal(preview.state, "missing");
  assert.deepEqual(calls[0], {
    command: commands.previewRunInputAttachment,
    payload: {
      generation: "7",
      previewId: "1",
      taskId: "17",
      runId: "23",
      attachmentIndex: 1,
    },
  });
  assert.deepEqual(
    calls.slice(1).map((call) => call.command),
    [commands.releasePreview],
  );
});

test("original bytes including a trailer round trip through sequential aligned chunks and close before display", async () => {
  const host = new Host();
  host.bytes = Buffer.concat([png, Buffer.alloc(524300, 0x7a)]);
  const result = await host.load();
  assert.equal(result.state, "ready");
  assert.deepEqual(
    Buffer.from(result.image.src.split(",")[1], "base64"),
    host.bytes,
  );
  assert.equal(host.active.size, 0);
  assert.deepEqual(
    host.calls
      .filter((x) => x.command === commands.readPreviewImage)
      .map((x) => x.payload.offset),
    ["0", "262143", "524286"],
  );
  result.release();
  assert.equal(result.image.src, "");
  assert.equal(result.image.valid(), false);
});

test("Host busy requeues the request with a fresh identity rather than publishing file error", async () => {
  const host = new Host();
  host.busy = 1;
  const result = await host.load();
  assert.equal(result.state, "ready");
  assert.deepEqual(
    host.calls
      .filter((x) => x.command === commands.previewFile)
      .map((x) => x.payload.previewId),
    ["1", "2"],
  );
  assert.equal(host.active.size, 0);
  result.release();
});

test("cancel before descriptor completion releases that request and never starts receiving", async () => {
  const host = new Host();
  const waiting = deferred(),
    entered = deferred();
  const original = host.invoke.bind(host);
  host.invoke = async (command, payload) => {
    if (command === commands.previewFile) {
      entered.resolve();
      await waiting.promise;
    }
    return original(command, payload);
  };
  const controller = new AbortController();
  const pending = host.load("image", { signal: controller.signal });
  await entered.promise;
  controller.abort();
  waiting.resolve();
  await assert.rejects(pending, { name: "AbortError" });
  assert.equal(
    host.calls.filter((x) => x.command === commands.readPreviewImage).length,
    0,
  );
  assert.equal(host.active.size, 0);
});

test("malformed chunk identity is rejected and both Host and Renderer reservations are released", async () => {
  const host = new Host();
  host.onRead = (payload) => ({
    state: "ready",
    token: BigInt(payload.previewId).toString(16).padStart(48, "0"),
    offset: "1",
    bytes: String(png.length),
    dataBase64: png.toString("base64"),
  });
  await assert.rejects(host.load(), /Invalid preview chunk identity/);
  assert.equal(host.active.size, 0);
  host.onRead = undefined;
  const next = await host.load();
  assert.equal(next.state, "ready");
  next.release();
});

test("security epoch revokes delivered content and notifies subscribers exactly once", async () => {
  const host = new Host();
  const result = await host.load();
  let notifications = 0;
  const off = result.image.subscribe(() => notifications++);
  host.loader.observeSecurityEpoch("2");
  assert.equal(result.image.valid(), false);
  assert.equal(result.image.src, "");
  assert.equal(notifications, 1);
  result.release();
  off();
  assert.equal(notifications, 1);
});

test("security change retries once after observing the new epoch and reopens the original reference", async () => {
  const host = new Host();
  host.loader.observeSecurityEpoch("1");
  let changed = false;
  host.onRead = () => {
    if (changed) return;
    changed = true;
    host.epoch = "2";
    host.loader.observeSecurityEpoch("2");
    return { state: "stale_security" };
  };
  const result = await host.load();
  assert.equal(result.image.securityEpoch, "2");
  assert.equal(
    host.calls.filter((x) => x.command === commands.previewFile).length,
    2,
  );
  assert.equal(host.active.size, 0);
  result.release();
});

test("a second security change does not create an automatic retry loop", async () => {
  const host = new Host();
  host.loader.observeSecurityEpoch("1");
  host.onRead = () => {
    host.epoch = String(BigInt(host.epoch) + 1n);
    host.loader.observeSecurityEpoch(host.epoch);
    return { state: "stale_security" };
  };
  await assert.rejects(host.load());
  assert.equal(
    host.calls.filter((x) => x.command === commands.previewFile).length,
    2,
  );
  assert.equal(host.active.size, 0);
});

test("window pixel quota admits two 4096-square resources, retains them and frees capacity explicitly", async () => {
  const host = new Host();
  host.width = 4096;
  host.height = 4096;
  const first = await host.load(),
    second = await host.load();
  const third = await host.load();
  assert.equal(third.reason, "capacity");
  assert.ok(first.image.valid() && second.image.valid());
  assert.equal(host.active.size, 0);
  first.release();
  const replacement = await host.load();
  assert.equal(replacement.state, "ready");
  second.release();
  replacement.release();
});

test("reset invalidates held resources and decode admission is serial and cancellable", async () => {
  const host = new Host();
  const first = await host.load(),
    second = await host.load();
  const a = new AbortController(),
    b = new AbortController();
  const release = await first.image.beginDecode(a.signal);
  const next = second.image.beginDecode(b.signal);
  b.abort();
  await assert.rejects(next, { name: "AbortError" });
  release();
  host.loader.reset();
  assert.equal(first.image.src, "");
  assert.equal(second.image.src, "");
  const reopened = await host.load();
  reopened.release();
});

test("a text preview can finish while image receipt is blocked", async () => {
  const host = new Host();
  const read = deferred(),
    entered = deferred();
  host.onRead = async () => {
    entered.resolve();
    await read.promise;
  };
  const first = host.load(),
    second = host.load();
  await entered.promise;
  const text = await host.load("text", { priority: "interactive" });
  assert.equal(text.content, "text is available");
  read.resolve();
  const images = await Promise.all([first, second]);
  for (const image of images) image.release();
  assert.equal(host.active.size, 0);
});
