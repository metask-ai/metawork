import assert from "node:assert/strict";
import test from "node:test";
import {
  commandLineToken,
  parseMcpCommandLine,
  validMcpArgv,
  parseMcpConfiguration,
} from "../frontend/src/features/mcp/configuration-input.ts";

test("strict configuration rejects duplicates, comments, trailing commas and excessive depth without echoing input", () => {
  for (const source of [
    '{"mcpServers":{"secret-name":{"command":"a","command":"b"}}}',
    '{"mcpServers":{"a":{"command":"node",}}}',
    '{/* secret */"mcpServers":{"a":{"command":"node"}}}',
    '{"mcpServers":{},"mcpServers":{}}',
    "[".repeat(34) + "0" + "]".repeat(34),
    " ".repeat(256 * 1024 + 1),
    '{"mcpServers":{}}',
  ]) {
    assert.throws(
      () => parseMcpConfiguration(source),
      (error) =>
        ["invalid", "duplicate_key", "depth_limit"].includes(error.message),
    );
  }
});

test("generic import preserves argv and separates password values from public drafts", () => {
  const result = parseMcpConfiguration(
    JSON.stringify({
      mcpServers: {
        local: {
          command: "node",
          args: ["", "--filter=$HOME", "`literal`", "--port", "3000"],
          env: { PORT: "3000" },
          disabled: false,
          autoApprove: ["all"],
        },
        remote: {
          type: "streamable-http",
          url: "https://example.test/mcp",
          headers: { Authorization: "Bearer synthetic-secret" },
        },
        unsupported: { command: "node", envFile: ".env" },
        disabled: { command: "node", disabled: true },
        wrongType: { command: "node", disabled: "false" },
        expression: { command: "node", env: { TOKEN: "${env:KEY}" } },
      },
    }),
  );
  assert.equal(result.entries.length, 2);
  assert.deepEqual(result.entries[0].draft.arguments, [
    "",
    "--filter=$HOME",
    "`literal`",
    "--port",
    "3000",
  ]);
  assert.deepEqual(result.entries[0].draft.environmentNames, ["PORT"]);
  assert.equal(result.entries[0].secrets.PORT, "3000");
  assert.equal(result.entries[0].ignoredPermissions, true);
  assert.equal(
    result.entries[1].secrets.Authorization,
    "Bearer synthetic-secret",
  );
  assert.equal(
    JSON.stringify(result.entries.map((entry) => entry.draft)).includes(
      "synthetic-secret",
    ),
    false,
  );
  assert.deepEqual(
    result.issues.map((issue) => issue.code),
    ["unsupported", "unsupported", "invalid", "variables"],
  );
});

test("import rejects conflicting fields, reserved slots, invalid endpoints and credential byte overflow", () => {
  for (const value of [
    { command: "node", url: "https://example.test" },
    { command: "node", args: [1] },
    { command: "node", env: { Path: "bad" } },
    { command: "node", env: { A: "a", a: "b" } },
    { url: "https://example.test/mcp#fragment" },
    { url: "https://example.test", headers: { Host: "bad" } },
    { command: "node", env: { TOKEN: "界".repeat(4) } },
  ])
    assert.equal(
      parseMcpConfiguration(
        JSON.stringify({ mcpServers: { test: value } }),
        10,
        "windows",
      ).entries.length,
      0,
    );
});

test("HTTP configuration preserves endpoint query bytes", () => {
  const url = "https://example.test?key=synthetic%2Bvalue&route=mcp";
  const result = parseMcpConfiguration(
    JSON.stringify({ mcpServers: { query: { url } } }),
  );
  assert.equal(result.issues.length, 0);
  assert.equal(result.entries[0].draft.endpoint, url);
});

test("Windows commands preserve drive, UNC and quoted paths", () => {
  for (const [input, expected] of [
    [
      "C:\\Tools\\server.exe --root C:\\data\\",
      [String.raw`C:\Tools\server.exe`, "--root", "C:\\data\\"],
    ],
    [
      String.raw`"C:\Program Files\server.exe" "C:\Data Files\\"`,
      [String.raw`C:\Program Files\server.exe`, "C:\\Data Files\\"],
    ],
    [String.raw`\\server\share\mcp.exe`, [String.raw`\\server\share\mcp.exe`]],
    [String.raw`'C:\My Tools\mcp.exe'`, [String.raw`C:\My Tools\mcp.exe`]],
  ])
    assert.deepEqual(parseMcpCommandLine(input, "windows"), expected);
});

test("POSIX command escaping remains platform specific", () => {
  assert.deepEqual(
    parseMcpCommandLine(
      String.raw`/Applications/My\ App/x "a\b" a\ b`,
      "posix",
    ),
    ["/Applications/My App/x", String.raw`a\b`, "a b"],
  );
});

for (const platform of ["windows", "posix"]) {
  test(`${platform}: formatter and editor preserve literal argv`, () => {
    const samples = [
      "",
      " ",
      "plain",
      "with space",
      "C:\\Tools\\",
      String.raw`\\server\share`,
      "a'b",
      'a"b',
      String.raw`a\"b`,
      "--filter=$HOME",
      "`literal`",
      "a|b",
      "a&b",
      "$(literal)",
      "世界",
    ];
    for (const command of [
      "node",
      String.raw`C:\My Tools\mcp.exe`,
      "/Applications/My App/x",
    ])
      for (const argument of samples) {
        const argv = [command, argument];
        assert.deepEqual(
          parseMcpCommandLine(
            argv.map((value) => commandLineToken(value, platform)).join(" "),
            platform,
          ),
          argv,
        );
      }
  });
  test(`${platform}: malformed and shell commands are rejected`, () => {
    for (const value of [
      "",
      'node "unterminated',
      "node | tee out",
      "node > file",
      "node $(whoami)",
      "node `whoami`",
      "node $HOME",
    ])
      assert.equal(parseMcpCommandLine(value, platform), null, value);
  });
}

test("argv validation preserves empty arguments and enforces total Host argument budget", () => {
  assert.equal(validMcpArgv(["node", "", "$HOME"]), true);
  assert.equal(validMcpArgv(["", "arg"]), false);
  assert.equal(
    validMcpArgv(["node", "a".repeat(8193), "b".repeat(8192)]),
    false,
  );
  assert.equal(validMcpArgv(["node", ...Array(129).fill("")]), false);
  assert.equal(validMcpArgv(["node", "a\nb"]), false);
});
