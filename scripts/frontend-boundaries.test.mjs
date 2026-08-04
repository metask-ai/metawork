import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const sourceRoot = fileURLToPath(new URL("../frontend/src/", import.meta.url));

async function sourceFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await sourceFiles(path)));
    else if (/\.(?:ts|tsx)$/.test(entry.name) && !entry.name.endsWith(".d.ts"))
      files.push(path);
  }
  return files;
}

function sourceParts(path) {
  return relative(sourceRoot, path).split(sep);
}

function relativeImports(source) {
  return new Set(
    [
      ...source.matchAll(
        /(?:from\s+|import\s*\()\s*["'](\.{1,2}\/[^"']+)["']/g,
      ),
      ...source.matchAll(/\bimport\s+["'](\.{1,2}\/[^"']+)["']/g),
    ].map((match) => match[1]),
  );
}

test("Renderer modules preserve the approved dependency direction", async () => {
  const files = await sourceFiles(sourceRoot);
  const paths = new Set(files.map((path) => relative(sourceRoot, path)));
  assert.equal(paths.has("App.tsx"), false, "App composition belongs in app/");
  assert.equal(paths.has(`app${sep}App.tsx`), true);
  assert.equal(
    [...paths].some(
      (path) => path.startsWith(`workbench${sep}`) && path.endsWith(".tsx"),
    ),
    false,
    "workbench/ owns projection consumption, not React product views",
  );

  for (const file of files) {
    const source = await readFile(file, "utf8");
    const parts = sourceParts(file);
    const layer = parts[0];
    if (layer === "workbench")
      assert.equal(
        /from\s+["']react/.test(source),
        false,
        `${relative(sourceRoot, file)} must stay React-free`,
      );
    if (!(layer === "bridge" && parts.join("/") === "bridge/client.ts"))
      assert.equal(
        source.includes("window.zero"),
        false,
        `${relative(sourceRoot, file)} bypasses the Host client boundary`,
      );

    for (const specifier of relativeImports(source)) {
      const targetParts = sourceParts(resolve(dirname(file), specifier));
      if (layer === "bridge")
        assert.equal(
          ["app", "features", "workbench", "components", "i18n"].includes(
            targetParts[0],
          ),
          false,
          `${relative(sourceRoot, file)} imports product layer ${specifier}`,
        );
      if (layer === "workbench")
        assert.equal(
          ["app", "features", "components", "i18n"].includes(targetParts[0]),
          false,
          `${relative(sourceRoot, file)} imports UI layer ${specifier}`,
        );
      if (layer === "components")
        assert.equal(
          ["app", "features", "bridge", "workbench"].includes(targetParts[0]),
          false,
          `${relative(sourceRoot, file)} is not a reusable UI primitive`,
        );
      if (
        layer === "features" &&
        targetParts[0] === "features" &&
        targetParts[1] !== parts[1]
      )
        assert.fail(
          `${relative(sourceRoot, file)} reaches into feature ${targetParts[1]}`,
        );
    }
  }
});

test("login-first composition gates every Workbench surface on Host readiness", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  const gate = app.indexOf('snapshot.account.readiness !== "ready"');
  const shell = app.indexOf("<AppShell");
  assert.ok(gate >= 0 && shell > gate);
  assert.match(app, /<AccountGate/);
  assert.match(app, /selectAccountGateStatus\(statuses\)/);
  assert.doesNotMatch(app, /setStatus\(\s*\{/);
  assert.doesNotMatch(app, /AccountPrerequisite|prerequisite=\{/);
  assert.doesNotMatch(
    await readFile(
      resolve(sourceRoot, "features", "composer", "ComposerFooter.tsx"),
      "utf8",
    ),
    /Account|prerequisite/,
  );
});

test("Task persistence failure disables mutations without hiding Task history", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  const taskList = await readFile(
    resolve(sourceRoot, "features", "tasks", "TaskList.tsx"),
    "utf8",
  );
  assert.match(
    app,
    /const workbenchMutationDisabled =\s*bridgeUnavailable \|\|\s*taskHistoryMutationBlocked\(/,
  );
  assert.match(
    app,
    /const taskMutationDisabled =\s*workbenchMutationDisabled \|\|/,
  );
  assert.match(
    app,
    /actionDisabled=\{workbenchMutationDisabled \|\| workspaceBusy\}/,
  );
  assert.match(app, /<TaskList[\s\S]*tasks=\{navigableTaskItems\}/);
  assert.doesNotMatch(taskList, /disabled=/);
});

test("Task selection invalidates an older asynchronous Workspace draft selection", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  assert.match(
    app,
    /function openTask\(taskId: string\) \{[\s\S]*?workspaceSelectionIntents\.current\.invalidate\(\);[\s\S]*?dispatchWorkbench\(\{ type: "task\.selected", taskId \}\);[\s\S]*?\}/,
  );
  assert.match(app, /onSelectTask=\{openTask\}/);
  assert.match(app, /openTask\(result\.taskId\)/);
});

test("Task and draft contexts do not recreate a global active Workspace", async () => {
  const [app, store, selectors] = await Promise.all([
    readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8"),
    readFile(resolve(sourceRoot, "workbench", "store.ts"), "utf8"),
    readFile(resolve(sourceRoot, "workbench", "selectors.ts"), "utf8"),
  ]);
  assert.doesNotMatch(app, /navigationWorkspaceId|activeWorkspaceId/);
  assert.doesNotMatch(store, /activeWorkspaceId/);
  assert.doesNotMatch(selectors, /selectCurrentWorkspace/);
  assert.match(app, /const defaultDraftWorkspaceId = selectedUserWorkspaceId/);
  assert.match(
    app,
    /const composerWorkspaceId =\s*activeTask\?\.workspaceId \|\|\s*workbench\.draftWorkspaceId \|\|\s*defaultDraftWorkspaceId/,
  );
});

test("Workspace lifecycle recovery lives in Settings with explicit focus handling", async () => {
  const [app, settings] = await Promise.all([
    readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8"),
    readFile(
      resolve(sourceRoot, "features", "settings", "WorkspaceSettings.tsx"),
      "utf8",
    ),
  ]);
  assert.match(app, /workspace\.origin === "user"/);
  assert.match(settings, /userWorkspaces: WorkspaceView\[\]/);
  assert.match(settings, /lastRemovalFailure/);
  assert.match(settings, /removalCancel\.current\?\.focus\(\)/);
  assert.match(settings, /event\.key !== "Escape"/);
  assert.match(settings, /onRemoveWorkspace\(workspaceId\)/);
  assert.match(
    app,
    /intent\.kind === "reauthorize"[\s\S]*result\.workspaceId !== intent\.workspaceId[\s\S]*kind: "target_mismatch"/,
  );
  assert.doesNotMatch(settings, /dispatchWorkbench|selectWorkspace/);
});

test("Renderer command bars own the hidden-inset titlebar without stealing control input", async () => {
  const shell = await readFile(
    resolve(sourceRoot, "app", "AppShell.tsx"),
    "utf8",
  );
  const gate = await readFile(
    resolve(sourceRoot, "features", "account", "AccountGate.tsx"),
    "utf8",
  );
  const css = await readFile(resolve(sourceRoot, "index.css"), "utf8");
  const titlebar = await readFile(
    resolve(sourceRoot, "components", "ui", "WindowTitlebar.tsx"),
    "utf8",
  );
  const icons = await readFile(
    resolve(sourceRoot, "components", "ui", "Icon.tsx"),
    "utf8",
  );
  const manifest = await readFile(
    new URL("../app.zon", import.meta.url),
    "utf8",
  );

  assert.match(shell, /workbench-commandbar/);
  assert.match(shell, /attentionNotice/);
  assert.match(shell, /commandbar-alert-slot/);
  assert.match(shell, /aria-live="polite"/);
  assert.match(shell, /WindowTitlebar/);
  assert.match(gate, /account-gate-toolbar/);
  assert.match(gate, /WindowTitlebar/);
  assert.match(titlebar, /onPointerDown=\{beginDrag\}/);
  assert.match(titlebar, /onDoubleClick=/);
  assert.match(titlebar, /onContextMenu=/);
  assert.doesNotMatch(`${shell}\n${gate}`, /onPointerMove|setPointerCapture/);
  assert.match(manifest, /\.titlebar = "hidden_inset_tall"/);
  assert.doesNotMatch(css, /-webkit-app-region:/);
  assert.match(shell, /WindowControls/);
  assert.match(gate, /WindowControls/);
  assert.match(css, /\[data-platform="windows"\] \.window-controls/);
  assert.match(css, /--window-bar-height: 52px/);
  assert.match(
    css,
    /\[data-platform="windows"\] \{[\s\S]*--window-bar-height: 40px/,
  );
  assert.match(
    css,
    /\[data-platform="windows"\] \.workbench-commandbar \{[\s\S]*padding-top: 0;[\s\S]*padding-bottom: 0;/,
  );
  assert.match(icons, /} from "lucide-react";/);
  assert.match(icons, /minimize: Minus/);
  assert.match(icons, /maximize: Square/);
  assert.match(icons, /restore: Copy/);
  assert.match(
    css,
    /top: calc\(var\(--window-bar-height\) \+ env\(safe-area-inset-top, 0px\)\)/,
  );
  assert.doesNotMatch(css, /top: calc\(48px \+ env\(safe-area-inset-top/);
  assert.doesNotMatch(
    `${shell}\n${gate}`,
    /app-titlebar|account-gate-titlebar/,
  );
});

test("timed-out mutations resync from Host state without automatic replay", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  const client = await readFile(
    resolve(sourceRoot, "bridge", "client.ts"),
    "utf8",
  );

  assert.match(client, /Promise\.race\(\[pending, timeout\]\)/);
  assert.match(client, /BridgeCommandTimeoutError/);
  assert.doesNotMatch(client, /catch[^{]*\{[^}]*this\.invoke/s);
  assert.match(
    app,
    /instanceof BridgeCommandTimeoutError[\s\S]*await refreshSnapshot\(\)/,
  );
  assert.match(app, /async function cancelAccountOperation\(\)/);
  assert.doesNotMatch(
    app,
    /runAccountCommand\(\(\) => client\.cancelAccountOperation\(\)\)/,
  );
});
