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

const skills = [
  {
    skillId: "skill-review",
    invocationName: "code-review",
    displayName: "Review code changes",
    description:
      "Review code changes for correctness, security, and maintainability.",
    argumentNames: ["target", "focus"],
    maxValues: 64,
  },
  {
    skillId: "skill-release",
    invocationName: "release-check",
    displayName: "Check before release",
    description: "Check versions, tests, and build state before release.",
    argumentNames: [],
    maxValues: 64,
  },
];

const readyCatalog = {
  availability: "ready",
  redacted: false,
  revision: "revision-4",
  skills,
  issues: [],
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
        workspaceName: "metawork",
        catalog: readyCatalog,
        query: "",
        refreshing: false,
        disabled: false,
        onQuery() {},
        onRefresh() {},
        onChooseWorkspace() {},
        onNewTask() {},
        ...props,
      }),
    ),
  );
}

test("Skills center renders the canonical Workspace catalog as a read-only list", () => {
  const markup = render();
  assert.match(markup, /<h1[^>]*tabindex="-1"[^>]*>Skills<\/h1>/);
  assert.match(markup, /Skills available to MetaWork in metawork/);
  assert.match(markup, /type="search"/);
  assert.match(markup, /code-review/);
  assert.match(markup, /Review code changes/);
  assert.match(markup, /Arguments: target · focus/);
  assert.match(markup, /release-check/);
  assert.match(markup, /No arguments/);
  assert.match(markup, /2 available/);
  assert.doesNotMatch(
    markup,
    /install|uninstall|enable|disable|checkbox|switch|\.claude|\.metacodes/i,
  );
});

test("Skills search covers invocation, display name, description, and arguments", () => {
  assert.deepEqual(
    filterSkills(skills, "SECURITY").map((skill) => skill.skillId),
    ["skill-review"],
  );
  assert.deepEqual(
    filterSkills(skills, "focus").map((skill) => skill.skillId),
    ["skill-review"],
  );
  assert.deepEqual(
    filterSkills(skills, "before release").map((skill) => skill.skillId),
    ["skill-release"],
  );
  assert.equal(filterSkills(skills, "missing").length, 0);
  assert.equal(filterSkills(skills, "  ").length, 2);
});

test("Skills center distinguishes no Workspace, loading, unavailable, empty, and no results", () => {
  const noWorkspace = render({ workspaceName: null, catalog: null });
  assert.match(noWorkspace, /Choose a workspace/);
  assert.match(noWorkspace, />Add<\/button>/);
  assert.doesNotMatch(noWorkspace, /disabled="">Add<\/button>/);
  assert.match(
    render({
      catalog: {
        ...readyCatalog,
        availability: "loading",
        revision: null,
        skills: [],
      },
    }),
    /skills-skeleton/,
  );
  assert.match(
    render({
      catalog: {
        ...readyCatalog,
        availability: "unavailable",
        revision: null,
        skills: [],
      },
    }),
    /Skills could not be loaded/,
  );
  assert.match(
    render({ catalog: { ...readyCatalog, skills: [] } }),
    /No skills found/,
  );
  assert.match(render({ query: "not-here" }), /No matching skills/);
});

test("degraded catalogs keep usable skills and expose bounded issue copy", () => {
  const markup = render({
    catalog: {
      ...readyCatalog,
      availability: "degraded",
      issues: [
        {
          code: "invalid_definition",
          invocationName: "release-notes",
        },
        {
          code: "source_conflict",
          invocationName: "review",
        },
      ],
    },
  });
  assert.match(markup, /code-review/);
  assert.match(markup, /Catalog issues: 2/);
  assert.match(markup, /release-notes/);
  assert.match(markup, /Invalid definition/);
  assert.match(markup, /Conflicting definitions/);
});

test("refreshing and failed refresh preserve the last committed list", () => {
  assert.match(
    render({
      refreshing: true,
      catalog: {
        ...readyCatalog,
        availability: "loading",
        revision: null,
      },
    }),
    /code-review/,
  );
  assert.match(
    render({
      catalog: {
        ...readyCatalog,
        availability: "unavailable",
        revision: null,
      },
    }),
    /code-review/,
  );
});

test("Skills route reuses the existing Workspace refresh command and owns no policy path", async () => {
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
  assert.match(app, /setRoute\("skills"\)/);
  assert.match(app, /aria-current=\{route === "skills" \? "page"/);
  assert.doesNotMatch(
    app,
    /className="sidebar-capability focus-ring"[\s\S]*?disabled=\{bridgeUnavailable\}[\s\S]*?setRoute\("skills"\)/,
  );
  assert.match(app, /client\.refreshWorkspaceSkillCatalog/);
  assert.match(
    app,
    /\(currentWorkspace !== undefined &&\s*currentWorkspace\.authorization !== "available"\)/,
  );
  assert.doesNotMatch(app, /currentWorkspace\?\.authorization !== "available"/);
  assert.match(page, /title\.current\?\.focus\(\)/);
  assert.doesNotMatch(
    commands,
    /skills\.(?:install|uninstall|enable|disable)|skillPolicy/i,
  );
  assert.doesNotMatch(
    page,
    /window\.zero|localStorage|FileSystem|toggle|switch/i,
  );
});

test("Skills route sees Workspace attention without leaking Task attention", () => {
  assert.equal(
    statusVisibleInCommandBar(
      {
        id: "skills.catalog_refresh_failed",
        tone: "attention",
        audience: { scope: "workspace", workspaceId: "7" },
      },
      { route: "skills", workspaceId: "7", taskId: "9" },
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
      { route: "skills", workspaceId: "7", taskId: "9" },
    ),
    false,
  );
});
