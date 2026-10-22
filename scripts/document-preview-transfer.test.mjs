import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { DocumentPreviewLoader } from "../frontend/src/bridge/document-preview.ts";
import { PreviewImagePool } from "../frontend/src/bridge/preview-image-pool.ts";
import { FilePreviewLoader } from "../frontend/src/bridge/file-preview.ts";
import { commands } from "../frontend/src/bridge/commands.ts";
import { BridgeClient } from "../frontend/src/bridge/client.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL("../src/bridge/document_preview.fixture", import.meta.url),
    "utf8",
  ),
);
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8k8AAAAASUVORK5CYII=",
  "base64",
);
const tick = () => new Promise((resolve) => setImmediate(resolve));

test("Bridge client owns invalidation subscriptions and drops old connection events", async () => {
  const host = new Host();
  let connection = 0;
  let stopped = 0;
  const listeners = [];
  const client = new BridgeClient({
    bridge: {
      async invoke(command, payload) {
        if (command === commands.connect)
          return {
            accepted: true,
            contractId: "metawork.renderer-bridge",
            contractRevision: 1,
            generation: String(++connection),
            error: null,
            attachmentInput: { mode: "native_paths", maxChunkBytes: "131072" },
          };
        return host.invoke(command, payload);
      },
      on(name, listener) {
        assert.equal(name, "metawork:document-preview-invalidated");
        listeners.push(listener);
        return () => {
          stopped++;
        };
      },
    },
  });
  await client.connect();
  const first = client.previewDocument("17", "23", {
    kind: "output",
    id: "03".repeat(16),
  });
  await tick();
  await client.connect();
  assert.equal(stopped, 1);
  assert.equal(first.getSnapshot().state, "cancelled");
  const second = client.previewDocument("17", "23", {
    kind: "fileReference",
    id: "ref",
  });
  await tick();
  listeners[0]({
    generation: "1",
    previewId: "1",
    token: fixture.open.token,
    reason: "expired",
  });
  assert.equal(second.getSnapshot().state, "ready");
  listeners[1]({
    generation: "2",
    previewId: "2",
    token: fixture.open.token,
    reason: "expired",
  });
  assert.equal(second.getSnapshot().state, "expired");
  await second.close();
});
function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
class Host {
  calls = [];
  generation = "1";
  time = 0;
  openHook;
  readHook;
  chunkHook;
  closeHook;
  pool = new PreviewImagePool();
  loader = new DocumentPreviewLoader(
    (...args) => this.invoke(...args),
    () => this.generation,
    this.pool,
    () => this.time,
  );
  async invoke(command, payload) {
    this.calls.push({ command, payload });
    if (command === commands.openDocument)
      return (
        this.openHook?.(payload) ?? {
          ...fixture.open,
          generation: payload.generation,
          previewId: payload.previewId,
        }
      );
    if (command === commands.readDocument)
      return (
        this.readHook?.(payload) ?? {
          ...fixture.page,
          readId: payload.readId,
          image: {
            ...fixture.page.image,
            sizeBytes: String(png.length),
            width: 1,
            height: 1,
          },
        }
      );
    if (command === commands.readDocumentChunk)
      return (
        this.chunkHook?.(payload) ?? {
          state: "ready",
          readId: payload.readId,
          offset: payload.offset,
          bytes: String(png.length),
          dataBase64: png.toString("base64"),
        }
      );
    if (command === commands.releaseDocumentRead)
      return { state: "ready", readId: payload.readId, released: true };
    assert.equal(command, commands.closeDocument);
    return (
      this.closeHook?.(payload) ?? {
        state: "ready",
        ...payload,
        released: true,
      }
    );
  }
  open(signal) {
    return this.loader.open(
      "17",
      "23",
      { kind: "fileReference", id: "ref" },
      signal,
    );
  }
}
test("document pages transfer once, release Host bytes, and clear previous page bytes", async () => {
  const host = new Host(),
    handle = host.open();
  await tick();
  assert.equal(handle.getSnapshot().state, "ready");
  await handle.read({ kind: "page", page: "1" });
  const first = handle.getSnapshot().content.image;
  assert.equal(first.src, `data:image/png;base64,${png.toString("base64")}`);
  await handle.read({ kind: "page", page: "2" });
  assert.equal(first.src, "");
  assert.equal(first.valid(), false);
  assert.equal(
    host.calls.filter((c) => c.command === commands.openDocument).length,
    1,
  );
  assert.equal(
    host.calls.filter((c) => c.command === commands.releaseDocumentRead).length,
    2,
  );
  const second = handle.getSnapshot().content.image;
  assert.equal(await handle.close(), true);
  assert.equal(second.src, "");
});
test("abort before a delayed open sends close immediately and cannot resurrect content", async () => {
  const host = new Host(),
    pending = deferred(),
    abort = new AbortController();
  host.openHook = () => pending.promise;
  const handle = host.open(abort.signal);
  abort.abort();
  await tick();
  assert.equal(
    host.calls.filter((c) => c.command === commands.closeDocument).length,
    1,
  );
  pending.resolve({ ...fixture.open, generation: "1", previewId: "1" });
  await tick();
  assert.equal(handle.getSnapshot().state, "cancelled");
});
test("security epoch revokes both page and region content, and blocks a late read", async () => {
  const host = new Host(),
    handle = host.open();
  await tick();
  await handle.read({ kind: "page", page: "1" });
  const image = handle.getSnapshot().content.image;
  host.loader.observeSecurityEpoch("2");
  assert.equal(image.src, "");
  assert.equal(handle.getSnapshot().state, "stale_security");
  await handle.close();
  host.loader.reset();
  host.openHook = (p) => ({
    ...fixture.open,
    generation: p.generation,
    previewId: p.previewId,
    kind: "grid",
    format: "xlsx",
    pageCount: 0,
    sheets: [{ index: 1, name: "Sheet", hidden: false, rows: 1, columns: 1 }],
  });
  const grid = host.open();
  await tick();
  host.readHook = (p) => ({ ...fixture.region, readId: p.readId });
  await grid.read({
    kind: "region",
    sheet: "1",
    row: "1",
    column: "1",
    rows: String(fixture.region.rows),
    columns: String(fixture.region.columns),
  });
  assert.equal(grid.getSnapshot().content.kind, "region");
  host.loader.observeSecurityEpoch("2");
  assert.deepEqual(grid.getSnapshot(), { state: "stale_security" });
  await grid.close();
});
test("wrong read, offset, byte count or padding fails without retaining an image", async () => {
  for (const mutate of [
    (v) => ({ ...v, readId: "99" }),
    (v) => ({ ...v, offset: "1" }),
    (v) => ({ ...v, bytes: "1" }),
    (v) => ({ ...v, dataBase64: "A".repeat(v.dataBase64.length) }),
  ]) {
    const host = new Host(),
      handle = host.open();
    await tick();
    host.chunkHook = (p) =>
      mutate({
        state: "ready",
        readId: p.readId,
        offset: "0",
        bytes: String(png.length),
        dataBase64: png.toString("base64"),
      });
    await handle.read({ kind: "page", page: "1" });
    assert.equal(handle.getSnapshot().state, "error");
    await handle.close();
  }
});
test("invalidation is generation and token scoped, including an event before open resolves", async () => {
  const host = new Host(),
    pending = deferred();
  host.openHook = () => pending.promise;
  const handle = host.open();
  host.loader.invalidated({
    generation: "1",
    previewId: "1",
    token: fixture.open.token,
    reason: "expired",
  });
  pending.resolve({ ...fixture.open, generation: "1", previewId: "1" });
  await tick();
  assert.equal(handle.getSnapshot().state, "expired");
  await handle.close();
  host.openHook = undefined;
  const live = host.open();
  await tick();
  host.loader.invalidated({
    generation: "2",
    previewId: "2",
    token: fixture.open.token,
    reason: "expired",
  });
  host.loader.invalidated({
    generation: "1",
    previewId: "2",
    token: "f".repeat(48),
    reason: "expired",
  });
  assert.equal(live.getSnapshot().state, "ready");
  await live.close();
});
test("cleanup debt consumes local slots and exposes restart required", async () => {
  const host = new Host();
  host.closeHook = (p) => ({
    state: "restart_required",
    ...p,
    released: false,
  });
  const a = host.open(),
    b = host.open();
  await tick();
  assert.equal(await a.close(), false);
  assert.equal(await b.close(), false);
  assert.equal(a.getSnapshot().state, "restart_required");
  const c = host.open();
  assert.equal(c.getSnapshot().state, "busy");
  assert.equal(
    host.calls.filter((c) => c.command === commands.openDocument).length,
    2,
  );
  host.loader.reset();
});
test("send-time transfer and idle deadlines reject delayed responses", async () => {
  const host = new Host(),
    handle = host.open();
  await tick();
  host.chunkHook = (p) => {
    host.time = 15001;
    return {
      state: "ready",
      readId: p.readId,
      offset: "0",
      bytes: String(png.length),
      dataBase64: png.toString("base64"),
    };
  };
  await handle.read({ kind: "page", page: "1" });
  assert.equal(handle.getSnapshot().state, "expired");
  await handle.close();
  const next = host.open();
  await tick();
  host.time += 120001;
  await next.read({ kind: "page", page: "1" });
  assert.equal(next.getSnapshot().state, "expired");
  await next.close();
});
test("document pages share image capacity and explicit DOM decode admission with ordinary previews", async () => {
  const host = new Host();
  const reservations = Array.from({ length: 32 }, (_, id) =>
    host.pool.reserve({
      id: String(id),
      mediaType: "image/png",
      sizeBytes: 1,
      width: 1,
      height: 1,
      securityEpoch: "1",
    }),
  );
  const handle = host.open();
  await tick();
  await handle.read({ kind: "page", page: "1" });
  assert.equal(handle.getSnapshot().state, "error");
  await handle.close();
  host.pool.clear();
  assert.ok(reservations.every((item) => !item.image.valid()));
  const a = host.open(),
    b = host.open();
  await tick();
  await a.read({ kind: "page", page: "1" });
  await b.read({ kind: "page", page: "1" });
  const abort = new AbortController();
  const release = await a.getSnapshot().content.image.beginDecode(abort.signal);
  let admitted = false;
  const waiting = b
    .getSnapshot()
    .content.image.beginDecode(abort.signal)
    .then((done) => {
      admitted = true;
      return done;
    });
  await tick();
  assert.equal(admitted, false);
  release();
  (await waiting)();
  // The same pool is also the ordinary FilePreviewLoader's resource owner.
  const ordinary = new FilePreviewLoader(
    async () => ({}),
    () => "1",
    host.pool,
  );
  ordinary.observeSecurityEpoch("1");
  assert.equal(
    a.getSnapshot().content.image.valid(),
    true,
    "the first matching epoch must not revoke another loader's image",
  );
  ordinary.reset();
  assert.equal(a.getSnapshot().content.image.valid(), false);
  await a.close();
  await b.close();
});
