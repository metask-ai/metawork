import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { releaseCsp } from "../frontend/csp.mjs";
import { verifyFrontendBuild } from "./verify-frontend-build.mjs";

async function frontendBuildFixture(t, css) {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-frontend-build-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const assetsPath = path.join(root, "frontend", "dist", "assets");
  await mkdir(assetsPath, { recursive: true });
  await writeFile(
    path.join(root, "frontend", "dist", "index.html"),
    `<meta http-equiv="Content-Security-Policy" content="${releaseCsp}">`,
  );
  await writeFile(path.join(assetsPath, "index.css"), css);
  return root;
}

test("production CSS accepts the current responsive contract", async (t) => {
  const root = await frontendBuildFixture(
    t,
    "@media (max-width:819px){}@media (max-width:619px){}@media (max-width:560px){}",
  );
  await assert.doesNotReject(verifyFrontendBuild(root));
});

test("the retired 1100px query cannot replace the 619px contract", async (t) => {
  const root = await frontendBuildFixture(
    t,
    "@media (max-width:1100px){}@media (max-width:819px){}@media (max-width:560px){}",
  );
  await assert.rejects(verifyFrontendBuild(root), /missing the 619px/u);
});
