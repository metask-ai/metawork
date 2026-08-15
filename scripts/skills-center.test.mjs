import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { SkillsPage, filterSkills } = await vite.ssrLoadModule(
  "/src/features/skills/SkillsPage.tsx",
);
const { statusVisibleInCommandBar } = await vite.ssrLoadModule(
  "/src/app/command-bar-status.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.after(async () => vite.close());

const assets = [
  {
    installId: "aabbccdd",
    sourceKind: "local_package",
    scope: { kind: "personal", workspaceId: null, workspaceEpoch: null },
    managementState: "ready",
    skillId: "skill-review",
    invocationName: "code-review",
    displayName: "Review code changes",
    description:
      "Review code changes for correctness, security, and maintainability.",
    argumentNames: ["target", "focus"],
    maxValues: 64,
    canExport: true,
    canReimport: true,
    canUninstall: true,
    canRetry: false,
    issueCodes: [],
  },
  {
    installId: "eeff0011",
    sourceKind: "local_directory",
    scope: { kind: "project", workspaceId: "1", workspaceEpoch: "1" },
    managementState: "pending_verification",
    skillId: null,
    invocationName: "release-check",
    displayName: "Check before release",
    description: "Check versions, tests, and build state before release.",
    argumentNames: [],
    maxValues: 64,
    canExport: false,
    canReimport: false,
    canUninstall: false,
    canRetry: true,
    issueCodes: [],
  },
  {
    installId: null,
    sourceKind: "external",
    scope: { kind: "external", workspaceId: null, workspaceEpoch: null },
    managementState: "externally_managed",
    skillId: "skill-notes",
    invocationName: "release-notes",
    displayName: "Release notes",
    description: "Create concise release notes.",
    argumentNames: ["range"],
    maxValues: 64,
    canExport: false,
    canReimport: false,
    canUninstall: false,
    canRetry: false,
    issueCodes: ["invalid_resource"],
  },
];

const readyManagement = { availability: "ready", assets };
const workspaces = [
  {
    id: "1",
    epoch: "1",
    kind: "manual",
    displayName: "MetaWork",
    authorization: "available",
  },
];

function render(props = {}) {
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(SkillsPage, {
        management: readyManagement,
        workspaces,
        query: "",
        refreshing: false,
        disabled: false,
        onQuery() {},
        onRefresh() {},
        async onChooseImport() {
          return { selected: false };
        },
        async onInstall() {
          return {
            accepted: true,
            installId: "aabbccdd",
            verificationPending: true,
            reason: null,
          };
        },
        async onReimport() {
          return {
            accepted: true,
            installId: "aabbccdd",
            verificationPending: true,
            reason: null,
          };
        },
        async onUninstall() {
          return {
            accepted: true,
            installId: "aabbccdd",
            verificationPending: true,
            reason: null,
          };
        },
        async onRetry() {
          return {
            accepted: true,
            installId: "aabbccdd",
            verificationPending: true,
            reason: null,
          };
        },
        async onExport() {
          return {
            exported: true,
            fileName: "code-review.skill",
            reason: null,
          };
        },
        async onDetail() {
          return {
            available: true,
            definition: "---\nname: code-review\n---\n",
            fileCount: 1,
            totalBytes: 42,
            reason: null,
          };
        },
        ...props,
      }),
    ),
  );
}

test("Skills center renders a compact local management surface", () => {
  const markup = render();
  assert.match(markup, /<h1[^>]*tabindex="-1"[^>]*>Skills<\/h1>/);
  assert.match(markup, /Manage local Skills available to MetaWork/);
  assert.match(markup, /type="search"/);
  assert.match(markup, /Import Skill/);
  assert.match(markup, /Needs attention/);
  assert.match(markup, /Review code changes/);
  assert.match(markup, /Check before release/);
  assert.match(markup, /Release notes/);
  assert.match(markup, /User/);
  assert.match(markup, /MetaWork/);
  assert.doesNotMatch(markup, />\/<|installed|checkbox|switch/i);
});

test("Skills search covers invocation, display name, description, and arguments", () => {
  assert.deepEqual(
    filterSkills(assets, "SECURITY").map((skill) => skill.skillId),
    ["skill-review"],
  );
  assert.deepEqual(
    filterSkills(assets, "focus").map((skill) => skill.skillId),
    ["skill-review"],
  );
  assert.deepEqual(
    filterSkills(assets, "before release").map((skill) => skill.skillId),
    [null],
  );
  assert.equal(filterSkills(assets, "missing").length, 0);
  assert.equal(filterSkills(assets, "  ").length, 3);
});

test("Skills center distinguishes unavailable, empty, and filtered states", () => {
  assert.match(
    render({ management: { availability: "unavailable", assets: [] } }),
    /Skill management is unavailable/,
  );
  assert.match(
    render({ management: { availability: "ready", assets: [] } }),
    /No local Skills yet/,
  );
  assert.match(render({ query: "not-here" }), /No matching Skills/);
});

test("Skills route uses the canonical management commands and no policy path", async () => {
  const app = await readFile(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  const commands = await readFile(
    join(process.cwd(), "frontend/src/bridge/commands.ts"),
    "utf8",
  );
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/skills/SkillsPage.tsx"),
    "utf8",
  );
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  assert.match(app, /management=\{snapshot\.skillManagement\}/);
  assert.match(app, /commitSkillMutation/);
  for (const command of [
    "chooseImport",
    "install",
    "reimport",
    "uninstall",
    "retry",
    "export",
    "detail",
    "refreshCatalog",
  ]) {
    assert.match(commands, new RegExp(`skills\\.${command}`));
  }
  assert.match(page, /title\.current\?\.focus\(\)/);
  assert.match(page, /<Drawer\.Root[\s\S]*?<Drawer\.Popup/);
  assert.doesNotMatch(
    page,
    /window\.zero|window\.confirm|localStorage|FileSystem|toggle|switch/i,
  );
  assert.match(
    css,
    /\.skill-header-actions > button \{[\s\S]*?display: inline-flex;[\s\S]*?width: auto;[\s\S]*?margin-top: 0;[\s\S]*?gap: 6px;/,
  );
  assert.match(css, /\.skill-empty-state > button \{\s*min-width: 168px;/);
});

test("Skills route sees global Skill attention without leaking Task attention", () => {
  assert.equal(
    statusVisibleInCommandBar(
      {
        id: "skills.catalog_refresh_failed",
        tone: "attention",
        audience: { scope: "skills" },
      },
      {
        route: "skills",
        settingsOpen: false,
        workspaceId: "7",
        taskId: "9",
      },
    ),
    true,
  );
  assert.equal(
    statusVisibleInCommandBar(
      {
        id: "run.failed",
        tone: "attention",
        audience: { scope: "task", taskId: "9" },
      },
      {
        route: "skills",
        settingsOpen: false,
        workspaceId: "7",
        taskId: "9",
      },
    ),
    false,
  );
});
