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
    /[\u0000-\u0020\u007f\\#]/.test(value) ||
    new TextEncoder().encode(value).length > 4096
  )
    return false;
  const authority = value.slice(value.indexOf("://") + 3).split(/[/?]/, 1)[0];
  const host = rawAuthorityHost(authority);
  if (host === null) return false;
  try {
    const endpoint = new URL(value);
    if (endpoint.username || endpoint.password || endpoint.hash) return false;
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
