// Restrict the two Office entry packages to the fixed private environment.
const { createRequire, registerHooks } = require("node:module");
const { pathToFileURL } = require("node:url");
const path = require("node:path");
if (require("./configuration.cjs").target !== "windows-x86_64")
  require("./finish.cjs").check(process.env.METAWORK_OFFICE_ENV);
const load = createRequire(
  path.join(process.env.METAWORK_OFFICE_ENV, "package.json"),
);
const entries = new Map(
  ["docx", "pptxgenjs"].map((name) => [
    name,
    pathToFileURL(load.resolve(name)).href,
  ]),
);
registerHooks({
  resolve(specifier, context, next) {
    return entries.has(specifier)
      ? { url: entries.get(specifier), shortCircuit: true }
      : next(specifier, context);
  },
});
process.argv = [process.execPath, ...process.argv.slice(3)];
if (!process.argv[1]) throw new Error("A JavaScript script is required");
process.argv[1] = path.resolve(process.argv[1]);
require("node:module").runMain();
