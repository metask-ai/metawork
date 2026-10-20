import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("Application installs image preparation after Product initialization and before ingress", async () => {
  const source = await readFile(
    new URL("../src/app.zig", import.meta.url),
    "utf8",
  );
  const startup = source.slice(
    source.indexOf("    fn start(context:"),
    source.indexOf("    fn stop(context:"),
  );
  const initialized = startup.indexOf("self.control_initialized = true;");
  const injection = startup.indexOf(".setImageRunPreparation(");
  const ingress = startup.indexOf(".startIngress()");
  assert.ok(
    initialized >= 0 && ingress > initialized,
    "Product must initialize before opening ingress",
  );
  assert.ok(
    injection > initialized && injection < ingress,
    "image preparation must attach to the live Product before any Run can start",
  );
  // The run() bootstrap only owns uninitialized storage and stable port addresses.
  const bootstrap = source.slice(source.indexOf("pub fn run("));
  assert.doesNotMatch(
    bootstrap,
    /\.setImageRunPreparation\(/,
    "bootstrap must not mutate uninitialized Product storage",
  );
});
