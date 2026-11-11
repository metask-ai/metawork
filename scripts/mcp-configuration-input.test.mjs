import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  commandLineToken,
  parseMcpCommandLine,
  validMcpArgv,
  validMcpHttpEndpoint,
} from "../frontend/src/features/mcp/configuration-input.ts";

test("MCP endpoint validation matches the Host authority contract", async () => {
  const { accepted, rejected } = JSON.parse(
    await readFile(
      new URL(
        "../src/product/mcp/testdata/mcp-http-endpoints.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  for (const endpoint of accepted)
    assert.equal(validMcpHttpEndpoint(endpoint), true, endpoint);
  for (const endpoint of rejected)
    assert.equal(validMcpHttpEndpoint(endpoint), false, endpoint);
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
  test(`${platform}: package command preserves quoted arguments`, () => {
    assert.deepEqual(
      parseMcpCommandLine(
        'npx -y "@modelcontextprotocol/server-filesystem" "/workspace files"',
        platform,
      ),
      [
        "npx",
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/workspace files",
      ],
    );
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
