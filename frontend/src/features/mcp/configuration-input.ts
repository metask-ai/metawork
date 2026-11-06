import {
  visit,
  parseTree,
  getNodeValue,
  type Node,
  type ParseError,
} from "jsonc-parser";
import type { McpInstallDraft } from "../../bridge/contracts.ts";
export type { McpInstallDraft } from "../../bridge/contracts.ts";
import { desktopPlatform } from "../../platform/keyboard.ts";

export type CommandPlatform = "windows" | "posix";
export function commandPlatform(): CommandPlatform {
  return desktopPlatform() === "windows" ? "windows" : "posix";
}

/** A command editor, never a shell. Structured argv bypasses this editor. */
export function parseMcpCommandLine(
  value: string,
  platform = commandPlatform(),
): string[] | null {
  const tokens: string[] = [];
  let token = "",
    quote: "'" | '"' | null = null,
    started = false;
  const input = value.trim();
  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    if (quote === "'") {
      if (c === "'") quote = null;
      else token += c;
      started = true;
      continue;
    }
    if (c === "\\") {
      started = true;
      if (platform === "windows") {
        let end = i;
        while (input[end] === "\\") end++;
        const count = end - i;
        if (input[end] === '"') {
          token += "\\".repeat(Math.floor(count / 2));
          if (count % 2) token += '"';
          else quote = quote === '"' ? null : '"';
          i = end;
        } else {
          token += "\\".repeat(count);
          i = end - 1;
        }
      } else {
        const next = input[i + 1];
        if (next === undefined) return null;
        if (quote === '"' && !/[\\"$`]/.test(next)) token += c;
        else {
          token += next;
          i++;
        }
      }
      continue;
    }
    if (c === '"') {
      quote = quote === '"' ? null : '"';
      started = true;
      continue;
    }
    if (quote === '"') {
      if (platform === "posix" && /[`$]/.test(c)) return null;
      token += c;
      started = true;
      continue;
    }
    if (c === "'") {
      quote = "'";
      started = true;
      continue;
    }
    if (/\s/.test(c)) {
      if (started) {
        tokens.push(token);
        token = "";
        started = false;
      }
      continue;
    }
    if (/[|&;<>`$]/.test(c)) return null;
    token += c;
    started = true;
  }
  if (quote !== null) return null;
  if (started) tokens.push(token);
  return validMcpArgv(tokens) ? tokens : null;
}

export function commandLineToken(
  value: string,
  platform = commandPlatform(),
): string {
  if (value && /^[A-Za-z0-9_./:@%+=,-]+$/.test(value)) return value;
  if (platform === "posix") return "'" + value.replaceAll("'", "'\\''") + "'";
  return (
    '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, "$1$1") + '"'
  );
}

function validText(
  value: unknown,
  max: number,
  empty = false,
): value is string {
  return (
    typeof value === "string" &&
    (empty || value.trim().length > 0) &&
    !/[\u0000-\u001f\u007f]/.test(value) &&
    new TextEncoder().encode(value).length <= max
  );
}

export function validMcpArgv(argv: string[]): boolean {
  return (
    argv.length > 0 &&
    argv.length <= 129 &&
    validText(argv[0], 4096) &&
    argv.slice(1).every((value) => validText(value, 16384, true)) &&
    argv
      .slice(1)
      .reduce(
        (total, value) => total + new TextEncoder().encode(value).length,
        0,
      ) <= 16384
  );
}

export type McpImportEntry = {
  draft: McpInstallDraft;
  secrets: Record<string, string>;
  ignoredPermissions: boolean;
  publicValueOverlap: boolean;
};
export type McpImportIssue = {
  name: string;
  code: "invalid" | "unsupported" | "variables";
};
export type McpImportResult = {
  entries: McpImportEntry[];
  issues: McpImportIssue[];
};
const own = (o: object, k: string) =>
  Object.prototype.hasOwnProperty.call(o, k);
function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function strings(value: unknown): string[] {
  if (
    !Array.isArray(value) ||
    value.length > 128 ||
    !value.every((x) => validText(x, 16384, true))
  )
    throw Error("invalid");
  return value;
}
function slots(
  value: unknown,
  header: boolean,
  secretMaxBytes: number,
  platform: CommandPlatform,
): Record<string, string> {
  if (value === undefined) return {};
  if (!record(value) || Object.keys(value).length > 128) throw Error("invalid");
  const result: Record<string, string> = Object.create(null);
  const names = new Set<string>();
  for (const [name, secret] of Object.entries(value)) {
    if (
      !validText(name, 256) ||
      !(
        header ? /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/ : /^[A-Za-z_][A-Za-z0-9_]*$/
      ).test(name) ||
      (!header &&
        (platform === "windows"
          ? /^(path|systemroot)$/i.test(name)
          : name === "PATH")) ||
      names.has(name.toLowerCase()) ||
      !validText(secret, secretMaxBytes)
    )
      throw Error("invalid");
    if (
      header &&
      /^(accept|accept-encoding|content-type|content-length|host|mcp-protocol-version|mcp-session-id)$/i.test(
        name,
      )
    )
      throw Error("unsupported");
    names.add(name.toLowerCase());
    result[name] = secret;
  }
  return result;
}

/** Only local, explicitly pasted password-form data may contain values. Never log this input/result. */
export function parseMcpConfiguration(
  text: string,
  secretMaxBytes = 16384,
  platform = commandPlatform(),
): McpImportResult {
  if (new TextEncoder().encode(text).length > importLimits.maxBytes)
    throw Error("invalid");
  const root: unknown = strictConfigurationJson(text);
  if (
    !record(root) ||
    Object.keys(root).length !== 1 ||
    !record(root.mcpServers) ||
    Object.keys(root.mcpServers).length === 0 ||
    Object.keys(root.mcpServers).length > importLimits.maxServers
  )
    throw Error("invalid");
  const result: McpImportResult = { entries: [], issues: [] };
  for (const [name, value] of Object.entries(root.mcpServers)) {
    try {
      if (!validText(name, 256) || !record(value)) throw Error("invalid");
      // Do not execute interpolation, read env files, infer scripts, or import grants.
      if (containsInterpolation(value)) throw Error("variables");
      if (value.disabled === true) throw Error("unsupported");
      if (value.disabled !== undefined && value.disabled !== false)
        throw Error("invalid");
      const allowed = new Set([
        "type",
        "command",
        "args",
        "cwd",
        "env",
        "url",
        "headers",
        "autoApprove",
        "alwaysAllow",
        "disabled",
      ]);
      if (Object.keys(value).some((k) => !allowed.has(k)))
        throw Error("unsupported");
      const ignoredPermissions =
        own(value, "autoApprove") || own(value, "alwaysAllow");
      const common = {
        displayName: name,
        negotiation: "automatic" as const,
        timeoutMs: 30000,
      };
      if (own(value, "command")) {
        if (value.type !== undefined && value.type !== "stdio")
          throw Error("unsupported");
        if (
          own(value, "url") ||
          own(value, "headers") ||
          !validText(value.command, 4096) ||
          (value.cwd !== undefined &&
            (!validText(value.cwd, 4096) ||
              !(platform === "windows"
                ? /^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)/.test(value.cwd)
                : value.cwd.startsWith("/"))))
        )
          throw Error("invalid");
        const secrets = slots(value.env, false, secretMaxBytes, platform);
        const arguments_ = value.args === undefined ? [] : strings(value.args);
        if (!validMcpArgv([value.command, ...arguments_]))
          throw Error("invalid");
        result.entries.push({
          draft: {
            ...common,
            transport: "stdio",
            command: value.command,
            arguments: arguments_,
            cwd: (value.cwd as string | undefined) ?? null,
            environmentNames: Object.keys(secrets),
          },
          secrets,
          ignoredPermissions,
          publicValueOverlap: Object.values(secrets).some((secret) =>
            [value.command, ...arguments_].some(
              (publicValue) =>
                typeof publicValue === "string" && publicValue.includes(secret),
            ),
          ),
        });
      } else {
        if (
          value.type !== undefined &&
          (typeof value.type !== "string" ||
            !["http", "streamable-http", "streamable_http"].includes(
              value.type,
            ))
        )
          throw Error("unsupported");
        if (
          own(value, "args") ||
          own(value, "cwd") ||
          own(value, "env") ||
          !validText(value.url, 4096) ||
          !validMcpHttpEndpoint(value.url)
        )
          throw Error("invalid");
        const secrets = slots(value.headers, true, secretMaxBytes, platform);
        result.entries.push({
          draft: {
            ...common,
            transport: "streamable_http",
            endpoint: value.url,
            authMode: Object.keys(secrets).length ? "static" : "none",
            headerNames: Object.keys(secrets),
            registration: null,
          },
          secrets,
          ignoredPermissions,
          publicValueOverlap: Object.values(secrets).some((secret) =>
            (value.url as string).includes(secret),
          ),
        });
      }
    } catch (error) {
      result.issues.push({
        name: validText(name, 256) ? name : "",
        code:
          error instanceof Error &&
          ["unsupported", "variables"].includes(error.message)
            ? (error.message as "unsupported" | "variables")
            : "invalid",
      });
    }
  }
  return result;
}

// Bounds are checked before constructing a recursive syntax tree.
const importLimits = {
  maxBytes: 256 * 1024,
  maxServers: 128,
  maxDepth: 32,
} as const;
function strictConfigurationJson(source: string): unknown {
  let depth = 0;
  const begin = () => {
    if (++depth > importLimits.maxDepth) throw Error("depth_limit");
  };
  const end = () => {
    depth--;
  };
  visit(
    source,
    {
      onObjectBegin: begin,
      onArrayBegin: begin,
      onObjectEnd: end,
      onArrayEnd: end,
      onError: () => {
        throw Error("invalid");
      },
    },
    {
      disallowComments: true,
      allowTrailingComma: false,
      allowEmptyContent: false,
    },
  );
  const errors: ParseError[] = [];
  const tree = parseTree(source, errors, {
    disallowComments: true,
    allowTrailingComma: false,
    allowEmptyContent: false,
  });
  if (!tree || errors.length) throw Error("invalid");
  function rejectDuplicates(node: Node): void {
    if (node.type === "object") {
      const seen = new Set<string>();
      for (const property of node.children ?? []) {
        const name = property.children![0].value as string;
        if (seen.has(name)) throw Error("duplicate_key");
        seen.add(name);
      }
    }
    for (const child of node.children ?? []) rejectDuplicates(child);
  }
  rejectDuplicates(tree);
  return getNodeValue(tree);
}
function containsInterpolation(value: unknown): boolean {
  if (typeof value === "string") return /\$\{|\$\(/.test(value);
  if (Array.isArray(value)) return value.some(containsInterpolation);
  if (record(value)) return Object.values(value).some(containsInterpolation);
  return false;
}

function rawAuthorityHost(authority: string): string | null {
  if (
    authority.length === 0 ||
    authority.includes("@") ||
    authority.includes("%") ||
    /[^\x00-\x7f]/.test(authority)
  )
    return null;

  let host: string;
  let port = "";
  if (authority.startsWith("[")) {
    const closingBracket = authority.indexOf("]");
    if (closingBracket < 0) return null;
    host = authority.slice(0, closingBracket + 1);
    port = authority.slice(closingBracket + 1);
  } else {
    const separator = authority.indexOf(":");
    if (separator < 0) {
      host = authority;
    } else {
      if (authority.indexOf(":", separator + 1) >= 0) return null;
      host = authority.slice(0, separator);
      port = authority.slice(separator);
    }
  }

  if (
    !host ||
    (port && !validRawAuthorityPort(port)) ||
    (!host.startsWith("[") && !validRawHostName(host))
  )
    return null;
  return host;
}

export function validMcpHttpEndpoint(value: string): boolean {
  if (
    !/^https?:\/\//i.test(value) ||
    /[\u0000-\u0020\u007f\\?#]/.test(value) ||
    new TextEncoder().encode(value).length > 4096
  )
    return false;
  const authority = value.slice(value.indexOf("://") + 3).split("/", 1)[0];
  const host = rawAuthorityHost(authority);
  if (host === null) return false;
  try {
    const endpoint = new URL(value);
    if (
      endpoint.username ||
      endpoint.password ||
      endpoint.search ||
      endpoint.hash
    )
      return false;
    if (endpoint.protocol === "https:") return true;
    return (
      endpoint.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(host.toLowerCase())
    );
  } catch {
    return false;
  }
}

function validRawAuthorityPort(value: string): boolean {
  if (!/^:[0-9]+$/.test(value)) return false;
  const port = Number(value.slice(1));
  return Number.isInteger(port) && port > 0 && port <= 65535;
}

function validRawHostName(value: string): boolean {
  const host = value.endsWith(".") ? value.slice(0, -1) : value;
  if (host.length === 0 || host.length > 255) return false;
  return host
    .split(".")
    .every(
      (label) =>
        label.length > 0 &&
        label.length <= 63 &&
        /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label),
    );
}
