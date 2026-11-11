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
    scope: { kind: "personal", workspaceId: null },
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
    enabled: true,
    enablementState: "enabled",
    canSetEnabled: true,
    selectionRevision: "3",
    issueCodes: [],
  },
  {
    installId: "eeff0011",
    sourceKind: "local_directory",
    scope: { kind: "project", workspaceId: "1" },
    managementState: "pending_verification",
    skillId: "skill-release",
    invocationName: "release-check",
    displayName: "Check before release",
    description: "Check versions, tests, and build state before release.",
    argumentNames: [],
    maxValues: 64,
    canExport: false,
    canReimport: false,
    canUninstall: false,
    canRetry: true,
    enabled: false,
    enablementState: "inherit",
    canSetEnabled: true,
    selectionRevision: "3",
    issueCodes: [],
  },
  {
    installId: null,
    sourceKind: "external",
    scope: { kind: "external", workspaceId: null },
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
    enabled: null,
    enablementState: null,
    canSetEnabled: false,
    selectionRevision: null,
    issueCodes: ["invalid_resource"],
  },
];

const readyManagement = {
  availability: "ready",
  enablementAvailability: "ready",
  personalSourceDiscovery: null,
  assets,
};
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
        personalCatalog: {
          revision: "personal-catalog-1",
          availability: "ready",
          issues: [],
        },
        query: "",
        refreshRequest: { busy: false, error: null },
        disabled: false,
        onQuery() {},
        onRefresh() {},
        async onSetEnabled() {
          return { applied: true, selectionRevision: "4", reason: null };
        },
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
  assert.match(markup, /Manage your personal Skills in MetaWork/);
  assert.match(markup, /aria-label="Search skills"/);
  assert.match(markup, />Import</);
  assert.match(markup, /Review code changes/);
  assert.match(markup, /<code>\/code-review<\/code>/);
  assert.doesNotMatch(markup, /User defaults|Project settings/);
  assert.match(markup, /role="switch"/);
  assert.doesNotMatch(markup, /Check before release/);
  assert.doesNotMatch(markup, /Release notes/);
  assert.doesNotMatch(markup, />All</);
  assert.doesNotMatch(markup, />\/<|installed/i);
});

test("Skills center distinguishes physical recovery from catalog verification", () => {
  const markup = render({
    management: {
      ...readyManagement,
      assets: [
        {
          ...assets[0],
          managementState: "recovery_required",
          canRetry: true,
          canExport: false,
          canReimport: false,
          canUninstall: false,
        },
      ],
    },
  });
  assert.match(markup, /Needs attention/);
  assert.match(markup, /Recovery required/);
  assert.doesNotMatch(markup, /Pending verification/);
});

test("management persistence failures explain restart even when no asset remains", () => {
  for (const availability of ["write_failed", "outcome_unknown"]) {
    const markup = render({
      management: { ...readyManagement, availability, assets: [] },
    });
    assert.match(markup, /role="status"/);
    assert.match(markup, /Restart MetaWork/);
    assert.match(markup, /folder access and file locks/);
    assert.doesNotMatch(markup, /Your first Skill/);
  }
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
    ["skill-release"],
  );
  assert.equal(filterSkills(assets, "missing").length, 0);
  assert.equal(filterSkills(assets, "  ").length, 3);
});

test("Skills center distinguishes unavailable, empty, and filtered states", () => {
  assert.match(
    render({
      management: {
        ...readyManagement,
        availability: "unavailable",
        enablementAvailability: "unavailable",
        assets: [],
      },
    }),
    /Skill management is unavailable/,
  );
  assert.match(
    render({
      management: {
        ...readyManagement,
        availability: "ready",
        enablementAvailability: "ready",
        assets: [],
      },
    }),
    /No local Skills yet/,
  );
  assert.match(render({ query: "not-here" }), /No matching Skills/);
});

test("Skills route uses canonical management and enablement commands", async () => {
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
    "setEnabled",
  ]) {
    assert.match(commands, new RegExp(`skills\\.${command}`));
  }
  assert.match(page, /title\.current\?\.focus\(\)/);
  assert.match(page, /<Drawer\.Root[\s\S]*?<Drawer\.Popup/);
  assert.doesNotMatch(
    page,
    /window\.zero|window\.confirm|localStorage|FileSystem/i,
  );
  assert.match(page, /<Switch\.Root/);
  assert.match(page, /expectedSelectionRevision/);
});

test("Skills and Task issues stay in their business contexts", () => {
  assert.equal(
    statusVisibleInCommandBar({
      id: "skills.catalog_refresh_failed",
      tone: "attention",
      audience: { scope: "skills" },
    }),
    false,
  );
  assert.equal(
    statusVisibleInCommandBar({
      id: "run.failed",
      tone: "attention",
      audience: { scope: "task", taskId: "9" },
    }),
    false,
  );
});
