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
    if (layer !== "bridge")
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

test("AI UI stays above Foundation UI and below product features", async () => {
  const aiRoot = resolve(sourceRoot, "components", "ai");
  const files = await sourceFiles(aiRoot);

  for (const file of files) {
    const source = await readFile(file, "utf8");
    const path = relative(sourceRoot, file);

    assert.doesNotMatch(
      source,
      /from\s+["']\.\.\/(?:features|bridge|workbench|app)\//,
      `${path} must not import product or transport owners`,
    );
    assert.doesNotMatch(
      source,
      /<(?:button|input|textarea)\b/,
      `${path} must compose Foundation controls instead of recreating them`,
    );

    for (const specifier of relativeImports(source)) {
      if (specifier.startsWith("../")) {
        assert.match(
          specifier,
          /^\.\.\/ui(?:\/|$)/,
          `${path} may only reach Foundation UI through ../ui/*`,
        );
      }
    }
  }
});

test("transitional Account states never turn signed-out history into a security gate", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  const gating = await readFile(
    resolve(sourceRoot, "features", "account", "gating.ts"),
    "utf8",
  );
  assert.match(app, /<AccountGate/);
  assert.match(app, /requiresAccountGate\(snapshot\.account\)/);
  assert.match(app, /selectAccountGateStatus\(statuses\)/);
  assert.match(
    gating,
    /state === "checking" \|\| account\.state === "authorizing"/,
  );
  assert.doesNotMatch(app, /workbenchEntered|setWorkbenchEntered/);
  assert.match(
    app,
    /\(!newTaskDraftActive \|\| snapshot\.account\.canCreateTask\)/,
  );
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
  assert.match(taskList, /className="task-list-item focus-ring"/);
  assert.match(taskList, /disabled=\{taskMutationDisabled/);
});

test("draft Workspace selection stays local until Task creation", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  assert.match(
    app,
    /function setDraftWorkspaceById\(workspaceId: string\) \{[\s\S]*?type: "task\.draft\.opened",[\s\S]*?workspaceId: workspace\.id/,
  );
  assert.doesNotMatch(app, /client\.selectWorkspace|WorkspaceSelectionIntents/);
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
  assert.doesNotMatch(app, /snapshot\.selectedWorkspaceId/);
  assert.match(
    app,
    /const composerWorkspaceId =\s*activeTask\?\.workspaceId \|\| workbench\.draftWorkspaceId/,
  );
});

test("Settings is a full content overlay that preserves the Workbench mount", async () => {
  const [app, shell, status, css] = await Promise.all([
    readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8"),
    readFile(resolve(sourceRoot, "app", "AppShell.tsx"), "utf8"),
    readFile(resolve(sourceRoot, "app", "command-bar-status.ts"), "utf8"),
    readFile(resolve(sourceRoot, "index.css"), "utf8"),
  ]);
  assert.match(
    app,
    /const \[settingsOpen, setSettingsOpen\] = useState\(false\)/,
  );
  assert.match(
    app,
    /settingsRestoreFocus = useRef<HTMLElement \| null>\(null\)/,
  );
  assert.match(
    app,
    /settingsRestoreFocus\.current\?\.focus\(\);[\s\S]*settingsRestoreFocus\.current = null/,
  );
  assert.match(app, /overlay=\{\s*settingsOpen \?/);
  assert.doesNotMatch(app, /route === "settings" \?\s*\(/);
  assert.doesNotMatch(app, /settingsOpen \? "settings" : route/);
  assert.doesNotMatch(status, /export type ShellRoute\s*=[^;]*"settings"/);
  assert.match(
    shell,
    /className="commandbar-leading-actions"[\s\S]*?inert=\{overlay \? true : undefined\}/,
  );
  assert.match(
    shell,
    /className="commandbar-context"[\s\S]*?inert=\{overlay \? true : undefined\}/,
  );
  assert.match(
    shell,
    /className="commandbar-alert-slot"[\s\S]*?inert=\{overlay \? true : undefined\}/,
  );
  assert.match(
    shell,
    /if \(overlay && attentionDetails\.current\)[\s\S]*?attentionDetails\.current\.open = false/,
  );
  assert.match(
    shell,
    /className="commandbar-alert-slot"[\s\S]*?<\/div>\s*<WindowControls/,
  );
  assert.match(
    shell,
    /className="app-columns" inert=\{overlay \? true : undefined\}/,
  );
  assert.match(
    css,
    /\.app-overlay-layer\s*\{[\s\S]*inset: var\(--window-bar-height\) 0 0;/,
  );
  assert.match(
    css,
    /\.settings-header,\s*\.settings-layout\s*\{[\s\S]*width: 100%;/,
  );
  assert.match(
    css,
    /\.settings-page\s*\{[\s\S]*--settings-navigation-track: calc\(var\(--left-column-width\) - 64px\);/,
  );
  assert.match(
    css,
    /\.settings-header\s*\{[\s\S]*grid-template-columns: var\(--settings-navigation-track\) minmax\(0, 1fr\);/,
  );
  assert.match(
    css,
    /\.settings-layout\s*\{[\s\S]*grid-template-columns: var\(--settings-navigation-track\) minmax\(0, 1fr\);/,
  );
  const settings = await readFile(
    resolve(sourceRoot, "features", "settings", "SettingsPage.tsx"),
    "utf8",
  );
  assert.match(settings, /role="dialog"/);
  assert.match(settings, /aria-modal="true"/);
  assert.doesNotMatch(settings, /settings-workspaces|WorkspaceSettings/);
});

test("Renderer draws declarative titlebar controls while Bridge and Host own native behavior", async () => {
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
  const controls = await readFile(
    resolve(sourceRoot, "components", "ui", "WindowControls.tsx"),
    "utf8",
  );
  const chromeBridge = await readFile(
    resolve(sourceRoot, "bridge", "window-chrome.ts"),
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
  assert.match(titlebar, /data-metawork-window-drag=""/);
  assert.match(titlebar, /createPortal\(dragRegion, document\.body\)/);
  assert.doesNotMatch(titlebar, /onPointerDown|onDoubleClick|onContextMenu/);
  assert.doesNotMatch(`${shell}\n${gate}`, /onPointerMove|setPointerCapture/);
  assert.match(manifest, /\.titlebar = "hidden_inset_tall"/);
  assert.doesNotMatch(css, /-webkit-app-region:/);
  assert.match(`${shell}\n${gate}`, /WindowControls/);
  assert.doesNotMatch(`${shell}\n${gate}`, /windowPlatform/);
  assert.match(controls, /data-metawork-window-control="minimize"/);
  assert.match(controls, /data-metawork-window-control="toggle_maximize"/);
  assert.match(controls, /data-metawork-window-control="close"/);
  assert.doesNotMatch(controls, /window\.zero|onClick|onPointer|onDoubleClick/);
  assert.doesNotMatch(css, /\[data-platform=/);
  assert.match(css, /\.window-controls/);
  assert.match(css, /--window-bar-height: 52px/);
  assert.match(
    chromeBridge,
    /const candidateSelector = "\[data-metawork-window-drag\]"/,
  );
  assert.match(chromeBridge, /commands\.windowChromeConnect/);
  assert.match(chromeBridge, /commands\.windowChromeSync/);
  assert.match(chromeBridge, /commands\.windowChromeControl/);
  assert.match(chromeBridge, /commands\.windowChromeDisconnect/);
  assert.match(chromeBridge, /decodeWindowChromeEnvironment/);
  assert.match(chromeBridge, /document\.querySelectorAll\(exclusionSelector\)/);
  assert.match(chromeBridge, /bridge\.on\("resize", scheduleSync\)/);
  assert.match(
    chromeBridge,
    /async function sync\(\)[\s\S]*commands\.windowChromeSync[\s\S]*generation === requestGeneration[\s\S]*value\.generation === requestGeneration/,
  );
  assert.match(
    chromeBridge,
    /const requestGeneration = generation;[\s\S]*generation: requestGeneration[\s\S]*generation === requestGeneration[\s\S]*value\.generation === requestGeneration/,
  );
  assert.match(
    chromeBridge,
    /commands\.windowChromeControl[\s\S]*\.catch\(\(\) => undefined\)/,
    "a transient button action failure must preserve the current document session",
  );
  assert.match(
    chromeBridge,
    /async function disconnect\([\s\S]*expectedGeneration:[\s\S]*generation !== current\) return/,
  );
  assert.doesNotMatch(
    chromeBridge,
    /window\.addEventListener\("resize"|async function refresh\(/,
  );
  assert.match(
    css,
    /\.window-drag-region \{[\s\S]*position: fixed;[\s\S]*width: 100vw;[\s\S]*height: var\(--metawork-window-chrome-top\)/,
  );
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

test("product CSS never overrides foundation popup geometry", async () => {
  const css = await readFile(resolve(sourceRoot, "index.css"), "utf8");
  // Popup resting geometry belongs to the ui presets (Dialog/Drawer). Product
  // stylesheets adapt through className utilities so tailwind-merge resolves
  // conflicts; custom-class geometry overrides depend on which CSS properties
  // the default utilities compile to, which is a library-internal detail.
  assert.doesNotMatch(
    css,
    /\.skill-drawer \{|\.mcp-drawer \{|\.scheduled-editor \{|\.search-dialog \{/,
  );
  assert.doesNotMatch(css, /translate: none/);
  assert.doesNotMatch(css, /(?<!text-)transform: none/);
});

test("overlay popups stay mounted while their root can animate closed", async () => {
  // Conditionally rendering a Base UI Popup inside its Portal removes the
  // element in the same commit that flips open to false. Base UI's exit
  // detection (useAnimationsFinished) bails out on a null element, the portal
  // subtree never unmounts, and the faded backdrop stays behind as an
  // invisible click shield. Condition the popup content, never the popup.
  const roots = ["features", "app", "components"];
  for (const root of roots) {
    const entries = await readdir(resolve(sourceRoot, root), {
      recursive: true,
    });
    for (const entry of entries) {
      if (!entry.endsWith(".tsx")) continue;
      const source = await readFile(resolve(sourceRoot, root, entry), "utf8");
      assert.doesNotMatch(
        source,
        /&&\s*\(\s*<[A-Z][A-Za-z]*\.(Popup|Backdrop)\b/,
        `${root}/${entry}: render the popup unconditionally and gate its content instead`,
      );
      assert.doesNotMatch(
        source,
        /\?\s*\(\s*<[A-Z][A-Za-z]*\.Popup\b[\s\S]{0,400}?:\s*null/,
        `${root}/${entry}: render the popup unconditionally and gate its content instead`,
      );
    }
  }
});
