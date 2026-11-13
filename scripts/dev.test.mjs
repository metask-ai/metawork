import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { createServer as createHttpServer } from "node:http";
import { readFileSync } from "node:fs";
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  developmentEnvironment,
  withDevelopmentServer,
  withDevelopmentDirectory,
  buildAppleDevelopmentRequirement,
  buildCanonicalDesignatedRequirement,
  isAppleDevelopmentIdentityName,
  localProductIdentity,
  parseCodeDirectoryIdentifier,
  parseCodeSigningIdentities,
  parseDesignatedRequirement,
  parseLocalSigningConfig,
  parseNativeProductIdentity,
  parseTeamIdentifier,
  selectLocalCodeSigningIdentity,
  validateCanonicalDesignatedRequirement,
} from "./dev.mjs";
import { xcodeContentsForDeveloperDirectory } from "./setup-macos-local-signing.mjs";
import { runChild } from "./run-child-process.mjs";

const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
const secondFingerprint = "FEDCBA9876543210FEDCBA9876543210FEDCBA98";
const certificateSuffix = "6L6UHLW8L7";
const teamId = "Z4T2BLNJ8X";
const identityName = `Apple Development: developer@example.com (${certificateSuffix})`;

test("development uses its owned Vite server without changing inherited environment", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-dev-env-"));
  const resources = path.join(root, "src", "product", "control", "resources");
  await mkdir(resources, { recursive: true });
  await writeFile(path.join(resources, "archive.py"), "");
  const inherited = {
    NATIVE_SDK_FRONTEND_URL: "http://old-server/",
    NATIVE_SDK_HMR: "0",
    NATIVE_SDK_MODE: "release",
    KEEP: "preserved",
  };
  try {
    const environment = developmentEnvironment(
      root,
      "http://127.0.0.1:5173/",
      inherited,
    );
    assert.equal(environment.NATIVE_SDK_FRONTEND_URL, "http://127.0.0.1:5173/");
    assert.equal(environment.NATIVE_SDK_HMR, "1");
    assert.equal(environment.NATIVE_SDK_MODE, "dev");
    assert.equal(environment.KEEP, "preserved");
    assert.equal(environment.METAWORK_DEV_REQUIRE_PRIMARY, "1");
    assert.equal(inherited.NATIVE_SDK_HMR, "0");
    assert.equal(inherited.NATIVE_SDK_FRONTEND_URL, "http://old-server/");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test(
  "development serves live modules, emits HMR updates and closes its server on Host exit or failure",
  { timeout: 30_000 },
  async () => {
    const root = await mkdtemp(path.join(tmpdir(), "metawork-dev-hmr-"));
    const frontend = path.join(root, "real", "frontend");
    const checkout = path.join(root, "checkout");
    await mkdir(frontend, { recursive: true });
    await symlink(path.dirname(frontend), checkout, "junction");
    const modulePath = path.join(frontend, "main.js");
    await writeFile(
      path.join(frontend, "index.html"),
      '<script type="module" src="/main.js"></script>',
    );
    await writeFile(
      modulePath,
      'export const label = "before"; import.meta.hot.accept();',
    );
    await writeFile(
      path.join(frontend, "vite.config.mjs"),
      'export default { logLevel: "silent", optimizeDeps: { noDiscovery: true }, server: { host: "127.0.0.1", port: 0, strictPort: true } };',
    );
    let ownedServer;
    try {
      await withDevelopmentServer(checkout, async (server) => {
        ownedServer = server;
        assert.equal(
          path.normalize(server.config.root),
          await realpath(frontend),
        );
        const url = server.resolvedUrls.local[0];
        const html = await (await fetch(url)).text();
        assert.match(html, /\/@vite\/client/);
        assert.match(
          await (await fetch(new URL("main.js", url))).text(),
          /before/,
        );
        const socket = new WebSocket(url.replace("http:", "ws:"), "vite-hmr");
        try {
          const [connected] = await once(socket, "message", {
            signal: AbortSignal.timeout(10_000),
          });
          assert.equal(JSON.parse(connected.data).type, "connected");
          const update = once(socket, "message", {
            signal: AbortSignal.timeout(10_000),
          });
          await writeFile(
            modulePath,
            'export const label = "after"; import.meta.hot.accept();',
          );
          const [message] = await update;
          const payload = JSON.parse(message.data);
          assert.equal(payload.type, "update");
          assert.ok(payload.updates.some((entry) => entry.path === "/main.js"));
          assert.match(
            await (await fetch(new URL("main.js", url))).text(),
            /after/,
          );
        } finally {
          socket.close();
        }
      });
      assert.equal(ownedServer.httpServer.listening, false);
      await assert.rejects(
        withDevelopmentServer(checkout, async (server) => {
          ownedServer = server;
          throw new Error("Host startup failed");
        }),
        /Host startup failed/,
      );
      assert.equal(ownedServer.httpServer.listening, false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
);

test(
  "development refuses an occupied Vite port instead of using another instance",
  { timeout: 30_000 },
  async () => {
    const root = await mkdtemp(path.join(tmpdir(), "metawork-dev-port-"));
    const frontend = path.join(root, "frontend");
    await mkdir(frontend);
    const occupied = createHttpServer();
    occupied.listen(0, "127.0.0.1");
    await once(occupied, "listening");
    try {
      await writeFile(
        path.join(frontend, "vite.config.mjs"),
        `export default { logLevel: "silent", optimizeDeps: { noDiscovery: true }, server: { host: "127.0.0.1", port: ${occupied.address().port}, strictPort: true } };`,
      );
      let hostStarted = false;
      await assert.rejects(
        withDevelopmentServer(root, () => {
          hostStarted = true;
        }),
        /already in use/,
      );
      assert.equal(hostStarted, false);
      assert.equal(occupied.listening, true);
    } finally {
      await new Promise((resolve, reject) =>
        occupied.close((error) => (error ? reject(error) : resolve())),
      );
      await rm(root, { recursive: true, force: true });
    }
  },
);

test(
  "the real development HTML permits the exact React refresh preamble without allowing arbitrary inline scripts",
  { timeout: 30_000 },
  async () => {
    const { createServer } = await import("vite");
    const server = await createServer({
      root: path.resolve(import.meta.dirname, "../frontend"),
      server: { port: 0 },
      logLevel: "silent",
    });
    try {
      await server.listen();
      const html = await (
        await fetch(server.resolvedUrls.local[0], {
          signal: AbortSignal.timeout(10_000),
        })
      ).text();
      assert.match(html, /\/@vite\/client/);
      assert.match(html, /\/@react-refresh/);
      const csp = html.match(
        /http-equiv="Content-Security-Policy" content="([^"]+)"/u,
      )?.[1];
      assert.ok(csp);
      const scriptPolicy = csp
        .split(";")
        .find((part) => part.trim().startsWith("script-src"));
      assert.doesNotMatch(scriptPolicy, /unsafe-inline|unsafe-eval/);
      for (const [, script] of html.matchAll(
        /<script\b[^>]*>([\s\S]*?)<\/script>/gu,
      )) {
        if (script.trim())
          assert.ok(
            scriptPolicy.includes(
              `'sha256-${createHash("sha256").update(script).digest("base64")}'`,
            ),
          );
      }
    } finally {
      await server.close();
    }
  },
);

test("development directories isolate overlapping sessions and clean only their own output", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-dev-test-"));
  try {
    const preserved = path.join(root, "preserved");
    await writeFile(preserved, "keep");
    let outer;
    let inner;
    await assert.rejects(
      withDevelopmentDirectory(root, async (first) => {
        outer = first;
        await withDevelopmentDirectory(root, async (second) => {
          inner = second;
          assert.notEqual(first, second);
          await writeFile(path.join(first, "output"), "first");
        });
        await assert.rejects(access(inner));
        await access(path.join(first, "output"));
        throw new Error("build failed");
      }),
      /build failed/,
    );
    await assert.rejects(access(outer));
    await access(preserved);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

for (const detachedDescendant of [false, true])
  for (const exitCode of [null, 7])
    test(
      `${exitCode === null ? "cancelled" : "failed"} development retains output while an owned ${detachedDescendant ? "detached " : ""}descendant is still running`,
      {
        skip: process.platform === "win32",
      },
      async () => {
        const root = await mkdtemp(
          path.join(tmpdir(), "metawork-dev-descendant-"),
        );
        const cancellation = new AbortController();
        let group;
        let descendant;
        let output;
        try {
          await assert.rejects(
            withDevelopmentDirectory(root, async (directory) => {
              output = directory;
              const ready = path.join(directory, "ready.json");
              const pending = runChild(
                process.execPath,
                [
                  "-e",
                  `
        const { spawn } = require('node:child_process');
        const child = spawn(process.execPath, ['-e', "process.on('SIGTERM', () => {}); process.send('ready'); setInterval(() => {}, 1000)"], { detached: ${detachedDescendant}, stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
        child.once('message', () => {
          require('node:fs').writeFileSync(process.argv[1], JSON.stringify({ group: process.pid, descendant: child.pid }));
          if (${exitCode} !== null) process.exit(${exitCode});
        });
        setInterval(() => {}, 1000);
      `,
                  ready,
                ],
                {
                  label: "owned process tree",
                  signal: cancellation.signal,
                  timeoutMs: null,
                },
              ).catch((error) => error);
              const deadline = Date.now() + 5000;
              while (group === undefined) {
                const bytes = await readFile(ready, "utf8").catch((error) => {
                  if (error.code === "ENOENT") return null;
                  throw error;
                });
                if (bytes) ({ group, descendant } = JSON.parse(bytes));
                else {
                  if (Date.now() >= deadline)
                    throw new Error("descendant did not start");
                  await new Promise((resolve) => setTimeout(resolve, 10));
                }
              }
              if (exitCode === null) cancellation.abort();
              const error = await pending;
              process.kill(descendant, 0);
              assert.equal(error.childProcessesMayBeRunning, true);
              throw error;
            }),
            exitCode === null
              ? /owned process tree cancelled/
              : /owned process tree failed with exit code 7/,
          );
          await access(path.join(output, "ready.json"));
        } finally {
          cancellation.abort();
          if (descendant && detachedDescendant) {
            try {
              process.kill(-descendant, "SIGKILL");
            } catch (error) {
              if (error.code !== "ESRCH") throw error;
            }
          }
          if (group) {
            try {
              process.kill(-group, "SIGKILL");
            } catch (error) {
              if (error.code !== "ESRCH") throw error;
            }
          }
          await rm(root, { recursive: true, force: true });
        }
      },
    );

test("development signing reads the existing Native product identity", () => {
  assert.deepEqual(localProductIdentity, {
    bundleId: "com.metask.metawork.dev",
    executableName: "metawork",
  });
  assert.deepEqual(
    parseNativeProductIdentity(
      `.{\n.id = "example.product.dev",\n.name = "product",\n}`,
    ),
    { bundleId: "example.product.dev", executableName: "product" },
  );
  assert.throws(
    () =>
      parseNativeProductIdentity(`.{ .id = "invalid", .name = "bad name" }`),
    /invalid native product identity/u,
  );
});

test("development has one cross-platform public entry", () => {
  const packageJson = JSON.parse(
    readFileSync(new URL("../package.json", import.meta.url), "utf8"),
  );
  assert.equal(packageJson.scripts.dev, "node scripts/dev.mjs");
});

test("local signing identity selection accepts one Apple Development identity", () => {
  const output = `
  1) ${fingerprint} "${identityName}"
     1 valid identities found
`;
  assert.deepEqual(parseCodeSigningIdentities(output), [
    { fingerprint, name: identityName },
  ]);
  assert.equal(isAppleDevelopmentIdentityName(identityName), true);
  assert.deepEqual(selectLocalCodeSigningIdentity(output), {
    fingerprint,
    name: identityName,
  });
});

test("identity display-name suffix is not treated as TeamIdentifier", () => {
  assert.notEqual(certificateSuffix, teamId);
  const config = {
    schemaVersion: 1,
    fingerprint,
    name: identityName,
    teamId,
  };
  assert.deepEqual(parseLocalSigningConfig(JSON.stringify(config)), config);
});

test("local signing identity selection rejects self-signed, missing, and ambiguous identities", () => {
  const selfSigned = `1) ${fingerprint} "MetaWork Local Development"`;
  assert.throws(
    () => selectLocalCodeSigningIdentity(selfSigned),
    /Apple Development.*found 0/u,
  );
  assert.throws(
    () => selectLocalCodeSigningIdentity("0 valid identities found"),
    /found 0/u,
  );
  const duplicate = `
  1) ${fingerprint} "${identityName}"
  2) ${secondFingerprint} "Apple Development: Second Developer (A1B2C3D4E5)"
     2 valid identities found
`;
  assert.throws(() => selectLocalCodeSigningIdentity(duplicate), /found 2/u);
  assert.deepEqual(selectLocalCodeSigningIdentity(duplicate, fingerprint), {
    fingerprint,
    name: identityName,
  });
});

test("local signing selection config has one strict schema", () => {
  const config = {
    schemaVersion: 1,
    fingerprint,
    name: identityName,
    teamId,
  };
  assert.deepEqual(parseLocalSigningConfig(JSON.stringify(config)), config);
  assert.throws(() => parseLocalSigningConfig("not json"), /not valid JSON/u);
  assert.throws(
    () => parseLocalSigningConfig(JSON.stringify({ ...config, extra: true })),
    /invalid schema/u,
  );
  assert.throws(
    () =>
      parseLocalSigningConfig(
        JSON.stringify({ ...config, name: "MetaWork Local Development" }),
      ),
    /invalid schema/u,
  );
  assert.throws(
    () =>
      parseLocalSigningConfig(JSON.stringify({ ...config, teamId: "not set" })),
    /invalid schema/u,
  );
});

test("development signature requires an Apple-issued TeamIdentifier", () => {
  assert.equal(parseTeamIdentifier(`TeamIdentifier=${teamId}\n`), teamId);
  assert.throws(
    () => parseTeamIdentifier("TeamIdentifier=not set\n"),
    /no Apple-issued Team Identifier/u,
  );
  assert.throws(
    () => parseTeamIdentifier(`Identifier=${localProductIdentity.bundleId}\n`),
    /did not contain TeamIdentifier/u,
  );
});

test("designated requirement parser rejects unstable CDHash identity", () => {
  const report = `
Identifier=${localProductIdentity.bundleId}
designated => cdhash H"0123456789abcdef"
`;
  assert.equal(
    parseCodeDirectoryIdentifier(report),
    localProductIdentity.bundleId,
  );
  assert.throws(() => parseDesignatedRequirement(report), /unstable CDHash/u);
});

test("designated requirement parsing does not depend on Apple's textual certificate chain", () => {
  const requirement = `designated => identifier "${localProductIdentity.bundleId}" and anchor apple generic and certificate leaf[subject.CN] = "${identityName}" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */`;
  const report = `Identifier=${localProductIdentity.bundleId}\n${requirement}\n`;
  assert.equal(parseDesignatedRequirement(report), requirement);
  assert.equal(
    parseDesignatedRequirement(
      `${requirement} and certificate 1[subject.OU] = "Apple Worldwide Developer Relations"`,
    ),
    `${requirement} and certificate 1[subject.OU] = "Apple Worldwide Developer Relations"`,
  );
  assert.throws(
    () => parseDesignatedRequirement("Identifier=missing"),
    /contained 0 designated requirements/u,
  );
  assert.throws(
    () =>
      parseDesignatedRequirement(
        `${requirement}\ndesignated => identifier "duplicate"`,
      ),
    /contained 2 designated requirements/u,
  );
});

test("canonical designated requirement validation rejects every other embedded policy", () => {
  const canonical = buildCanonicalDesignatedRequirement(
    localProductIdentity.bundleId,
    teamId,
    identityName,
  );
  assert.equal(
    validateCanonicalDesignatedRequirement(
      `Identifier=${localProductIdentity.bundleId}\n${canonical}\n`,
      canonical,
    ),
    canonical,
  );
  for (const weak of [
    "designated => true",
    `designated => identifier "${localProductIdentity.bundleId}" or true`,
    `designated => identifier "${localProductIdentity.bundleId}"`,
  ]) {
    assert.throws(
      () => validateCanonicalDesignatedRequirement(weak, canonical),
      /not the canonical MetaWork requirement/u,
    );
  }
});

test("Apple Development verification policy binds identifier, Apple anchor, Team, and certificate", () => {
  assert.equal(
    buildAppleDevelopmentRequirement(
      localProductIdentity.bundleId,
      teamId,
      identityName,
    ),
    `identifier "${localProductIdentity.bundleId}" and anchor apple generic and certificate leaf[subject.OU] = ${teamId} and certificate leaf[subject.CN] = "${identityName}"`,
  );
  assert.throws(
    () => buildAppleDevelopmentRequirement("invalid", teamId, identityName),
    /invalid identity metadata/u,
  );
  assert.throws(
    () =>
      buildAppleDevelopmentRequirement(
        localProductIdentity.bundleId,
        teamId,
        'Apple Development: invalid "name"',
      ),
    /invalid identity metadata/u,
  );
  assert.equal(
    buildCanonicalDesignatedRequirement(
      localProductIdentity.bundleId,
      teamId,
      identityName,
    ),
    `designated => identifier "${localProductIdentity.bundleId}" and anchor apple generic and certificate leaf[subject.OU] = ${teamId} and certificate leaf[subject.CN] = "${identityName}"`,
  );
});

test("Xcode WWDR lookup follows the selected developer directory", () => {
  assert.equal(
    xcodeContentsForDeveloperDirectory(
      "/Applications/Xcode-beta.app/Contents/Developer",
    ),
    "/Applications/Xcode-beta.app/Contents",
  );
  assert.equal(
    xcodeContentsForDeveloperDirectory("/Library/Developer/CommandLineTools"),
    null,
  );
});
