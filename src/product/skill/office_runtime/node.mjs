// Only explicit Office invocations load this hook. The two official authoring
// packages always resolve from the component, even beside a Workspace package
// with the same name. Their transitive dependencies keep Node's normal rules.
import { createRequire, registerHooks } from "node:module";
import { pathToFileURL } from "node:url";

const packageURL = new URL("../authoring/package.json", import.meta.url).href;
const require = createRequire(packageURL);
const entries = new Map(
  ["docx", "pptxgenjs"].map((name) => [
    name,
    pathToFileURL(require.resolve(name)).href,
  ]),
);
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (entries.has(specifier)) {
      return { url: entries.get(specifier), shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
});
