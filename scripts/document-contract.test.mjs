import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  decodeDocumentOpen,
  decodeDocumentRead,
  decodeDocumentChunk,
  decodeDocumentClose,
  decodeDocumentReleaseRead,
  decodeDocumentInvalidated,
} from "../frontend/src/bridge/document-contract.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL("../src/bridge/document_preview.fixture", import.meta.url),
    "utf8",
  ),
);
test("document wire fixture is accepted without exposing source text or paths", () => {
  assert.equal(decodeDocumentOpen(fixture.open).state, "ready");
  assert.equal(decodeDocumentRead(fixture.page).kind, "page");
  assert.equal(decodeDocumentRead(fixture.region).cells[0].formula, "=1+1");
  assert.equal(decodeDocumentChunk(fixture.chunk).bytes, "4");
  assert.equal(decodeDocumentClose(fixture.close).released, true);
  assert.equal(decodeDocumentReleaseRead(fixture.releaseRead).released, true);
  assert.equal(
    decodeDocumentInvalidated(fixture.invalidated).reason,
    "expired",
  );
  assert.throws(
    () =>
      decodeDocumentOpen({ ...fixture.open, sourceText: "PRIVATE-CONTENT" }),
    /unexpected fields/,
  );
});

test("region payload observes the same aggregate string budget as Host admission", () => {
  const cell = fixture.region.cells[0];
  const cells = Array.from({ length: 10 }, (_, index) => ({
    ...cell,
    row: index + 1,
    column: 1,
    display: "x".repeat(16000),
  }));
  assert.throws(
    () =>
      decodeDocumentRead({
        ...fixture.region,
        row: 1,
        column: 1,
        rows: 10,
        columns: 1,
        cells,
      }),
    /region exceeds capacity/,
  );
});
test("document variants, image budgets and correlation fields fail closed", () => {
  for (const value of [
    { ...fixture.open, token: "x".repeat(48) },
    { ...fixture.open, securityEpoch: "0" },
    { ...fixture.open, idleMs: "1200000" },
    { ...fixture.open, sourceBytes: "18446744073709551616" },
    { ...fixture.open, kind: "grid" },
  ])
    assert.throws(() => decodeDocumentOpen(value));
  assert.throws(() =>
    decodeDocumentRead({
      ...fixture.page,
      image: { ...fixture.page.image, height: 10000 },
    }),
  );
  assert.throws(() =>
    decodeDocumentRead({
      ...fixture.region,
      cells: [...fixture.region.cells, ...fixture.region.cells],
    }),
  );
  assert.throws(() =>
    decodeDocumentRead({
      ...fixture.region,
      cells: [{ ...fixture.region.cells[0], row: 11 }],
    }),
  );
  assert.throws(() =>
    decodeDocumentChunk({ ...fixture.chunk, dataBase64: "a".repeat(100000) }),
  );
  assert.throws(() =>
    decodeDocumentClose({ ...fixture.close, state: "restart_required" }),
  );
  assert.equal(
    decodeDocumentClose({
      ...fixture.close,
      state: "restart_required",
      released: false,
    }).released,
    false,
  );
});
test("document diagnostic failures do not carry untrusted values", () => {
  const sensitive = "PRIVATE-CONTENT";
  for (const decode of [
    decodeDocumentOpen,
    decodeDocumentRead,
    decodeDocumentChunk,
    decodeDocumentClose,
    decodeDocumentReleaseRead,
  ]) {
    assert.deepEqual(decode({ state: "busy" }), { state: "busy" });
    assert.throws(
      () => decode({ state: sensitive }),
      (error) => !error.message.includes(sensitive),
    );
    assert.throws(
      () => decode({ state: "restricted", [sensitive]: sensitive }),
      (error) => !error.message.includes(sensitive),
    );
  }
});
