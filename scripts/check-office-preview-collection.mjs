// Separate processes prove kernel lifetime and no-follow collection. This is
// qualification data, never a client install or an arbitrary path capability.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { readOfficeComponent } from "./office-environment.mjs";

if (process.platform !== "win32" || process.argv.length !== 5)
  throw Error(
    "Usage: check-office-preview-collection.mjs <prepared-component> <resource-probe.exe> <synthetic-fixtures>",
  );
const component = readOfficeComponent(path.resolve(process.argv[2]));
const probe = path.resolve(process.argv[3]);
const fixtures = path.resolve(process.argv[4]);
const cache = path.resolve(".zig-cache/pvc");
mkdirSync(cache, { recursive: true });
const directory = mkdtempSync(path.join(cache, "r-"));
const source = readFileSync(path.join(fixtures, "original.docx"));
const digest = createHash("sha256").update(source).digest("hex");
const cases = [];
const delay = () => new Promise((done) => setTimeout(done, 30));
const args = (root, mode) => [
  component.root,
  fixtures,
  "original.docx",
  root,
  String(source.length),
  digest,
  component.manifestSha256,
  mode,
];
const rootFor = (name) => {
  const root = path.join(directory, name);
  mkdirSync(root);
  return root;
};
const sweep = (root) =>
  JSON.parse(
    execFileSync(probe, args(root, "sweep"), {
      encoding: "utf8",
      timeout: 15000,
      maxBuffer: 65536,
      windowsHide: true,
    }),
  );

function hold(root) {
  const child = spawn(probe, args(root, "hold"), {
    windowsHide: true,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "",
    stderr = "",
    ready;
  child.stdout.on("data", (bytes) => {
    stdout += bytes;
    if (stdout.length > 65536) child.kill();
    const line = stdout.split("\n")[0];
    if (stdout.includes("\n") && !ready) ready = JSON.parse(line);
  });
  child.stderr.on("data", (bytes) => {
    stderr = (stderr + bytes).slice(-4096);
  });
  const exited = new Promise((done, fail) => {
    child.once("exit", (code, signal) => done({ code, signal }));
    child.once("error", fail);
  });
  return {
    child,
    exited,
    async ready() {
      const end = Date.now() + 30000;
      while (
        !ready &&
        child.exitCode === null &&
        child.signalCode === null &&
        Date.now() < end
      )
        await delay();
      if (!ready?.ready)
        throw Error(`Preview holder did not become ready: ${stderr}`);
      return ready;
    },
    async stop(kill) {
      if (child.exitCode === null && child.signalCode === null) {
        if (kill) assert.equal(child.kill(), true);
        else child.stdin.end("\n");
      }
      const result = await Promise.race([
        exited,
        new Promise((_, fail) =>
          setTimeout(() => fail(Error("Holder did not exit")), 10000).unref(),
        ),
      ]);
      if (!kill) assert.equal(result.code, 0, stderr);
      return result;
    },
  };
}
async function gone(root) {
  const end = Date.now() + 10000;
  let result;
  do {
    result = sweep(root);
    if (result.removed || !result.retained) return result;
    await delay();
  } while (Date.now() < end);
  throw Error(`Exited owner retained resources: ${JSON.stringify(result)}`);
}
function moveOwned(from, to) {
  for (const target of [from, to]) {
    const absolute = path.resolve(target);
    assert.ok(
      absolute.startsWith(directory + path.sep),
      "move stays in qualification directory",
    );
  }
  assert.equal(lstatSync(from).isSymbolicLink(), false);
  assert.equal(existsSync(to), false);
  renameSync(from, to);
}

// A ready owner has no running engine, but its resource is still in use.
{
  const root = rootFor("a"),
    owner = hold(root);
  try {
    const ready = await owner.ready();
    const result = sweep(root);
    assert.equal(result.removed, 0);
    assert.equal(result.retained, 1);
    assert.ok(existsSync(path.join(root, "pv", ready.operation, "prepared")));
    await owner.stop(false);
    assert.deepEqual(sweep(root), { removed: 0, retained: 0, limited: false });
    cases.push({ name: "live-ready-owner", result });
  } finally {
    await owner.stop(true);
  }
}
{
  const root = rootFor("b"),
    owner = hold(root);
  try {
    await owner.ready();
    await owner.stop(true);
    const result = await gone(root);
    assert.equal(result.removed, 1);
    assert.equal(readdirSync(path.join(root, "pv")).length, 0);
    cases.push({ name: "hard-killed-ready-owner", result });
  } finally {
    await owner.stop(true);
  }
}
// Crash once the durable owner record exists, without waiting for conversion.
{
  const root = rootFor("c"),
    owner = hold(root);
  try {
    const end = Date.now() + 10000;
    let registered = false;
    while (!registered && Date.now() < end) {
      const pv = path.join(root, "pv");
      registered =
        existsSync(pv) &&
        readdirSync(pv).some((name) =>
          existsSync(path.join(pv, name, ".owner.json")),
        );
      if (!registered) await delay();
    }
    assert.ok(registered);
    await owner.stop(true);
    const result = await gone(root);
    assert.equal(result.removed, 1);
    cases.push({ name: "hard-killed-preparing-owner", result });
  } finally {
    await owner.stop(true);
  }
}
for (const parentLink of [false, true]) {
  const root = rootFor(parentLink ? "e" : "d"),
    owner = hold(root);
  try {
    const ready = await owner.ready();
    await owner.stop(true);
    const original = parentLink
      ? path.join(root, "pv")
      : path.join(root, "pv", ready.operation);
    const outside = path.join(
      directory,
      parentLink ? "outside-parent" : "outside-child",
    );
    moveOwned(original, outside);
    const sentinel = path.join(outside, "sentinel.txt");
    writeFileSync(sentinel, "must remain");
    symlinkSync(outside, original, "junction");
    let result;
    try {
      result = sweep(root);
    } catch (error) {
      assert.ok(parentLink);
      result = { refused: true };
    }
    if (!parentLink) assert.equal(result.retained, 1);
    assert.equal(readFileSync(sentinel, "utf8"), "must remain");
    assert.ok(
      existsSync(
        path.join(outside, parentLink ? ready.operation : "", ".owner.json"),
      ),
    );
    cases.push({
      name: parentLink ? "namespace-junction" : "owned-directory-junction",
      result,
    });
  } finally {
    await owner.stop(true);
  }
}
{
  const root = rootFor("f"),
    name = randomBytes(16).toString("hex");
  mkdirSync(path.join(root, "pv", name), { recursive: true });
  writeFileSync(path.join(root, "pv", name, "user.txt"), "unregistered");
  const result = sweep(root);
  assert.equal(result.retained, 1);
  assert.equal(
    readFileSync(path.join(root, "pv", name, "user.txt"), "utf8"),
    "unregistered",
  );
  cases.push({ name: "missing-owner-record", result });
}
writeFileSync(
  path.join(directory, "evidence.json"),
  JSON.stringify(
    {
      scope:
        "Real Application preview resource owners and worker collection in separate Windows processes; no install or full Product UI authority",
      componentManifestSha256: component.manifestSha256,
      probeSha256: createHash("sha256")
        .update(readFileSync(probe))
        .digest("hex"),
      cases,
    },
    null,
    2,
  ),
);
console.log(JSON.stringify({ directory, cases: cases.length }));
