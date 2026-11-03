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
  assert.deepEqual(
    files.map((file) => relative(aiRoot, file)).sort(),
    [
      "Activity.tsx",
      "CodeBlock.tsx",
      "Composer.tsx",
      "Conversation.tsx",
      "Intervention.tsx",
      "Markdown.tsx",
      "Message.tsx",
      "index.ts",
    ],
    "AI UI keeps one minimal public rendering vocabulary",
  );

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

test("central conversation paths use only the shared AI UI vocabulary", async () => {
  const [taskContent, approval, composer] = await Promise.all([
    readFile(
      resolve(sourceRoot, "features", "tasks", "TaskContent.tsx"),
      "utf8",
    ),
    readFile(
      resolve(sourceRoot, "features", "approvals", "ApprovalPanel.tsx"),
      "utf8",
    ),
    readFile(
      resolve(sourceRoot, "features", "composer", "ComposerFooter.tsx"),
      "utf8",
    ),
  ]);

  assert.match(taskContent, /<Conversation/);
  assert.match(taskContent, /<Message\s+role="user"/);
  assert.match(taskContent, /<Message\s+role="assistant"/);
  assert.match(taskContent, /<Activity/);
  assert.match(approval, /<Intervention/);
  assert.match(composer, /<Composer/);

  const legacy =
    /task-content|task-turn|task-input"|assistant-response|task-active-status|task-outcome|inline-request|className="composer"/;
  assert.doesNotMatch(taskContent, legacy);
  assert.doesNotMatch(approval, legacy);
  assert.doesNotMatch(composer, legacy);
});

test("Account states never replace or reinterpret the Workbench", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  const newTask = await readFile(
    resolve(sourceRoot, "features", "tasks", "NewTaskView.tsx"),
    "utf8",
  );
  const accountIdentity = await readFile(
    resolve(sourceRoot, "features", "account", "AccountIdentity.tsx"),
    "utf8",
  );
  assert.doesNotMatch(app, /AccountGate|accountGateRequired/);
  assert.doesNotMatch(app, /accountSurfacePolicy|accountSetupRedirected/);
  assert.doesNotMatch(app, /newTaskSetup|task\.setup\./);
  assert.match(newTask, /\{composer\}/);
  assert.match(
    accountIdentity,
    /account\.state === "signed_out"[\s\S]*?onBeginLogin/,
  );
  assert.match(
    accountIdentity,
    /account\.state === "authorizing" && account\.canCancel[\s\S]*?onCancel/,
  );
  assert.doesNotMatch(app, /workbenchEntered|setWorkbenchEntered/);
  // New object admission still uses its actual model/Workspace authority.
  // Once identity acquisition began, continuous delivery uses that same Task.
  assert.match(
    app,
    /const canCreateTask =\s*snapshot\.newTaskAdmission\.available &&\s*newTaskWorkspaceReady &&\s*newTaskModelState\.valid/,
  );
  assert.match(
    app,
    /!newTaskDraftActive \|\| taskIdentityPending \|\| canCreateTask/,
  );
  assert.match(app, /activeTask\?\.inputAcceptance\.available/);
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

test("Task persistence failure remains diagnostic without blocking mutations", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  const store = await readFile(
    resolve(sourceRoot, "workbench", "store.ts"),
    "utf8",
  );
  const taskList = await readFile(
    resolve(sourceRoot, "features", "tasks", "TaskList.tsx"),
    "utf8",
  );
  const confirmationNotice = await readFile(
    resolve(sourceRoot, "components", "ConfirmationNotice.tsx"),
    "utf8",
  );
  assert.match(app, /const workbenchMutationDisabled =\s*bridgeUnavailable;/);
  assert.doesNotMatch(app, /taskHistoryMutationBlocked/);
  assert.doesNotMatch(store, /taskHistoryMutationBlocked/);
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
  assert.match(taskList, /disabled=\{\s*taskMutationDisabled/);
  assert.match(
    app,
    /<ConfirmationNotice[\s\S]*?className="task-persistence-error"[\s\S]*?actionAvailable=\{/,
  );
  assert.match(confirmationNotice, /className=\{className\} role="alert"/);
});

test("degraded Task history does not create a permanent sidebar alert", async () => {
  const app = await readFile(resolve(sourceRoot, "app", "App.tsx"), "utf8");
  assert.match(
    app,
    /taskHistoryPersistenceHealth !==\s*"degraded"[\s\S]*?task-persistence-error/,
  );
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
    /const composerWorkspaceId =\s*activeTask\?\.workspaceId \?\?\s*selectedTaskSummary\?\.workspaceId \?\?\s*workbench\.draftWorkspaceId/,
  );
  assert.match(
    app,
    /const selectedTaskSummary = snapshot\.taskIndex\.find\(\s*\(task\) => task\.id === workbench\.activeTaskId/,
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
  for (const group of [
    "commandbar-leading-actions",
    "commandbar-context",
    "commandbar-alert-slot",
  ]) {
    assert.match(
      shell,
      new RegExp(
        `className="${group}"[^>]*data-native-window-drag-exclude[\\s\\S]*?className="commandbar-inert-content"[\\s\\S]*?inert=\\{overlay \\? true : undefined\\}`,
      ),
    );
  }
  assert.match(css, /\.commandbar-inert-content\s*\{\s*display: contents;/);

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
    /\.settings-page\s*\{[\s\S]*--settings-navigation-track: var\(--left-column-width\);/,
  );
  assert.match(
    css,
    /\.settings-back-slot\s*\{[\s\S]*border-right: 1px solid var\(--settings-line\);[\s\S]*background: var\(--ui-surface-panel-2\);/,
  );
  assert.match(
    css,
    /\.settings-nav\s*\{[\s\S]*border-right: 1px solid var\(--settings-line\);[\s\S]*background: var\(--ui-surface-panel-2\);/,
  );
  assert.doesNotMatch(css, /\.settings-page::before/);
  assert.match(
    css,
    /\.settings-header\s*\{[\s\S]*grid-template-columns: var\(--settings-navigation-track\) minmax\(0, 1fr\);/,
  );
  assert.match(
    css,
    /\.settings-layout\s*\{[\s\S]*grid-template-columns: var\(--settings-navigation-track\) minmax\(0, 1fr\);/,
  );
  assert.match(
    css,
    /\.settings-nav a\s*\{[\s\S]*grid-template-columns: 22px minmax\(0, 1fr\);[\s\S]*min-height: 36px;/,
  );
  const settings = await readFile(
    resolve(sourceRoot, "features", "settings", "SettingsPage.tsx"),
    "utf8",
  );
  assert.match(settings, /role="dialog"/);
  assert.match(settings, /aria-modal="true"/);
  assert.match(
    settings,
    /className="settings-back-slot"[\s\S]*className="settings-back focus-ring"/,
  );
  assert.match(
    settings,
    /<Icon name="settings" \/>[\s\S]*<Icon name="account" \/>[\s\S]*<Icon name="model" \/>/,
  );
  assert.doesNotMatch(settings, /settings-workspaces|WorkspaceSettings/);
});

test("workbench columns use bounded proportional Flex without an overlay resizer", async () => {
  const shell = await readFile(
    resolve(sourceRoot, "app", "AppShell.tsx"),
    "utf8",
  );
  const css = await readFile(resolve(sourceRoot, "index.css"), "utf8");

  assert.match(
    css,
    /\.app-window\s*\{[^}]*grid-template-columns: minmax\(0, 1fr\);[^}]*\}/,
  );
  assert.match(
    css,
    /\.app-columns\s*\{[^}]*display: flex;[^}]*width: 100%;[^}]*min-width: 0;[^}]*overflow: hidden;/,
  );
  assert.doesNotMatch(css, /\.app-columns\s*\{[^}]*grid-template-columns:/);
  assert.match(
    css,
    /\.workspace-sidebar\s*\{[\s\S]*?flex: 0 0 var\(--left-column\);/,
  );
  assert.match(
    css,
    /data-right-panel-open="true"\]\[data-right-panel-docked="true"\][\s\S]*?\.task-panel\s*\{[\s\S]*?flex: 0 0 var\(--right-panel-width\);/,
  );
  assert.doesNotMatch(css, /--task-(?:stage|panel)-share/);
  assert.match(
    css,
    /\.workspace-sidebar,\s*\.task-panel\s*\{[\s\S]*?transition: flex-basis 170ms cubic-bezier\(0\.2, 0, 0, 1\);/,
  );
  assert.match(
    css,
    /data-resizing-left="true"[\s\S]*?data-resizing-right="true"[\s\S]*?\.task-panel\s*\{\s*transition: none;/,
  );
  assert.doesNotMatch(
    css,
    /data-right-panel-open="true"\]\[data-right-panel-docked="true"\]\s*\.task-panel\s*\{[^}]*max-width:/,
  );
  assert.match(
    css,
    /\.task-panel-resize-handle\s*\{[\s\S]*?position: relative;[\s\S]*?flex: 0 0 10px;[\s\S]*?margin-inline: -5px;/,
  );
  assert.doesNotMatch(
    css,
    /data-right-panel-docked="false"\] \.task-panel-resize-handle/,
  );
  assert.match(shell, /metawork\.panel\.task\.share/);
  assert.doesNotMatch(shell, /metawork\.panel\.task\.width/);
  assert.match(shell, /new ResizeObserver/);
  assert.match(shell, /ref=\{workbenchElement\}[\s\S]*?className="app-window"/);
  assert.doesNotMatch(shell, /<div\s+ref=\{[^}]+\}\s+className="app-columns"/);
  assert.match(shell, /\{effectiveRightPanelOpen && rightPanelDocked && \(/);
});

test("Renderer draws declarative titlebar controls while Bridge and Host own native behavior", async () => {
  const shell = await readFile(
    resolve(sourceRoot, "app", "AppShell.tsx"),
    "utf8",
  );
  const rootFailure = await readFile(
    resolve(
      sourceRoot,
      "features",
      "connection",
      "ConnectionFailureScreen.tsx",
    ),
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
  assert.match(rootFailure, /connection-failure-toolbar/);
  assert.match(rootFailure, /WindowTitlebar/);
  assert.match(titlebar, /data-native-window-drag=""/);
  assert.match(titlebar, /ref=\{ref\}/);
  assert.match(shell, /<WindowTitlebar ref=\{bindWindowTitlebar\}/);
  assert.match(rootFailure, /<WindowTitlebar\s+ref=\{bindWindowTitlebar\}/);
  assert.doesNotMatch(titlebar, /createPortal|window-drag-region/);
  assert.doesNotMatch(titlebar, /onPointerDown|onDoubleClick|onContextMenu/);
  assert.doesNotMatch(
    `${shell}\n${rootFailure}`,
    /onPointerMove|setPointerCapture/,
  );
  assert.match(manifest, /\.titlebar = "hidden_inset_tall"/);
  assert.match(manifest, /\.window_drag_regions = true/);
  assert.match(controls, /data-native-window-drag-exclude=""/);
  assert.match(
    rootFailure,
    /className="connection-failure-toolbar-actions"[\s\S]*?data-native-window-drag-exclude=""/,
  );
  assert.doesNotMatch(css, /-webkit-app-region:/);
  assert.match(`${shell}\n${rootFailure}`, /WindowControls/);
  assert.doesNotMatch(`${shell}\n${rootFailure}`, /windowPlatform/);
  assert.match(controls, /data-metawork-window-control="minimize"/);
  assert.match(controls, /data-metawork-window-control="toggle_maximize"/);
  assert.match(controls, /data-metawork-window-control="close"/);
  assert.doesNotMatch(controls, /window\.zero|onClick|onPointer|onDoubleClick/);
  assert.doesNotMatch(css, /\[data-platform=/);
  assert.match(css, /\.window-controls/);
  assert.match(css, /--window-bar-height: 52px/);
  assert.match(
    css,
    /\.app-window\[data-left-open="true"\] \.workbench-commandbar::before \{[\s\S]*?top: calc\(0px - env\(safe-area-inset-top, 0px\)\);/,
    "the left rail surface and divider must cross the native safe-area inset",
  );
  assert.match(
    css,
    /\.workspace-resize-handle::after \{[\s\S]*?position: fixed;[\s\S]*?top: 0;[\s\S]*?bottom: 0;[\s\S]*?left: calc\(var\(--left-column\) - 1px\);/,
    "left resize feedback must remain one continuous full-window divider",
  );
  assert.match(
    css,
    /\.app-window\[data-resizing-left="true"\] \.workspace-resize-handle::after/,
    "captured pointer resizing must preserve the continuous divider feedback",
  );
  assert.doesNotMatch(
    chromeBridge,
    /(?:document|window)\.addEventListener\("(?:pointerdown|mousedown|click|blur)"/,
  );
  assert.match(chromeBridge, /commands\.windowChromeConnect/);
  assert.match(chromeBridge, /commands\.windowChromeRefresh/);
  assert.doesNotMatch(
    chromeBridge,
    /windowChromeGesture|mousedown|pointerdown/,
  );
  assert.match(chromeBridge, /commands\.windowChromeControl/);
  assert.match(chromeBridge, /commands\.windowChromeDisconnect/);
  assert.match(chromeBridge, /decodeWindowChromeEnvironment/);
  assert.doesNotMatch(
    chromeBridge,
    /MutationObserver|ResizeObserver|getBoundingClientRect|windowChromeSync|ChromeRegion/,
  );
  assert.match(chromeBridge, /bridge\.on\("resize", scheduleRefresh\)/);
  assert.match(
    chromeBridge,
    /window\.addEventListener\("focus", scheduleRefresh\)/,
  );
  assert.match(chromeBridge, /event\.composedPath\(\)/);
  assert.match(chromeBridge, /refreshInFlight/);
  assert.match(chromeBridge, /stateEpoch === requestEpoch/);
  assert.match(chromeBridge, /value\.generation === requestGeneration/);
  assert.match(chromeBridge, /assertWindowChromeHandled/);
  assert.match(
    chromeBridge,
    /if \(disposed\) \{\s*void disconnect\(value\.generation\)/,
  );
  assert.doesNotMatch(chromeBridge, /window\.addEventListener\("resize"/);
  assert.doesNotMatch(css, /\.window-drag-region/);
  assert.match(
    css,
    /top: calc\(var\(--window-bar-height\) \+ env\(safe-area-inset-top, 0px\)\)/,
  );
  assert.doesNotMatch(css, /top: calc\(48px \+ env\(safe-area-inset-top/);
  assert.doesNotMatch(
    `${shell}\n${rootFailure}`,
    /app-titlebar|account-gate-titlebar|connection-failure-titlebar/,
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
