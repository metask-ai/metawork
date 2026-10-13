import { execFileSync } from "node:child_process";
import test from "node:test";

test("Office Skills carry exact self-contained copies of the canonical bounded archive helper", () => {
  execFileSync(process.execPath, [
    "scripts/sync-office-archive.mjs",
    "--check",
  ]);
});
