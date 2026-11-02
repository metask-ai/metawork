import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  runAttachmentCapacityVertical,
  verifyAttachmentBaselineArtifact,
} from "./attachment-capacity-vertical.mjs";

test("baseline admission requires an explicit frozen executable and matching digest", async (ctx) => {
  const directory = await mkdtemp(join(tmpdir(), "metawork-baseline-"));
  ctx.after(() => rm(directory, { recursive: true, force: true }));
  const binary = join(directory, "host");
  const bytes = Buffer.from("frozen fixture executable");
  await writeFile(binary, bytes);
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const input = {
    prebuilt: "1",
    binary,
    cwd: directory,
    expectedSha256: sha256,
  };
  for (const [field, value, message] of [
    ["prebuilt", undefined, /METAWORK_VERTICAL_PREBUILT/],
    ["prebuilt", "true", /METAWORK_VERTICAL_PREBUILT/],
    ["binary", undefined, /METAWORK_TEST_APP_BINARY/],
    ["cwd", undefined, /METAWORK_TEST_APP_CWD/],
    ["expectedSha256", undefined, /METAWORK_ATTACHMENT_BASELINE_SHA256/],
    ["expectedSha256", "a".repeat(64), /SHA-256 mismatch/],
  ]) {
    await assert.rejects(
      verifyAttachmentBaselineArtifact({ ...input, [field]: value }),
      message,
    );
  }
  assert.equal((await verifyAttachmentBaselineArtifact(input)).sha256, sha256);
  await writeFile(binary, "replaced executable");
  await assert.rejects(
    verifyAttachmentBaselineArtifact(input),
    /SHA-256 mismatch/,
  );
});

test("baseline mode fails before building when the frozen artifact was not supplied", () => {
  const env = { ...process.env, METAWORK_ATTACHMENT_BASELINE_ONLY: "1" };
  delete env.METAWORK_VERTICAL_PREBUILT;
  const result = spawnSync(
    process.execPath,
    ["scripts/test-agentcore-vertical-macos.mjs", "aarch64-macos"],
    { env, encoding: "utf8", timeout: 15_000 },
  );
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /baseline requires METAWORK_VERTICAL_PREBUILT=1/);
});

for (const oldPool of [true, false]) {
  test(
    `baseline probe ${oldPool ? "records the frozen artifact" : "rejects a larger pool"}`,
    { skip: process.platform !== "darwin" },
    async (ctx) => {
      const directory = await mkdtemp(join(tmpdir(), "metawork-capacity-"));
      ctx.after(() => rm(directory, { recursive: true, force: true }));
      const artifact = { path: "/fixture/host", sha256: "a".repeat(64) };
      let additions = 0;
      const cleaned = [];
      const run = runAttachmentCapacityVertical({
        baselineOnly: true,
        artifact,
        pid: process.pid,
        workspaceRoot: directory,
        evidenceDir: directory,
        pngFixture: () => Buffer.from("fixture"),
        invoke: async (command, payload) => {
          if (command === "metawork.attachments.cancelAdd") {
            cleaned.push(payload.batchId);
            return { status: "cleaned", released: true };
          }
          assert.equal(command, "metawork.attachments.beginAdd");
          additions++;
          if (oldPool && additions === 2)
            return { status: "rejected", reason: "staging_capacity" };
          return {
            status: "ready",
            attachments: payload.source.paths.map((_, id) => ({
              token: String(id),
            })),
          };
        },
      });
      if (oldPool) {
        await run;
        const evidence = JSON.parse(
          await readFile(join(directory, "attachment-capacity-baseline.json")),
        );
        assert.deepEqual(evidence.artifact, artifact);
      } else {
        await assert.rejects(run, /Expected values to be strictly deep-equal/);
        await assert.rejects(
          readFile(join(directory, "attachment-capacity-baseline.json")),
          { code: "ENOENT" },
        );
      }
      assert.equal(additions, 2);
      assert.deepEqual(cleaned.sort(), ["1000", "1001"]);
    },
  );
}
