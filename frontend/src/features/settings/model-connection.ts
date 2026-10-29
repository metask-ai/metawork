import type {
  BuiltinProviderPresetView,
  Protocol,
} from "../../bridge/contracts.ts";

const requestPaths: Record<Protocol, string> = {
  openai_responses: "/responses",
  openai_chat_completions: "/chat/completions",
  anthropic_messages: "/v1/messages",
  gemini_native: "",
};

export function builtinProviderEndpoint(preset: BuiltinProviderPresetView) {
  return `${preset.defaultBaseUrl.replace(/\/+$/u, "")}${requestPaths[preset.protocol]}`;
}

export type EndpointIssue = "address" | "secure" | "path";
export function inspectModelEndpoint(value: string): {
  protocol: Protocol | null;
  root: boolean;
  issue: EndpointIssue | null;
} {
  const address = value.trim();
  const invalid = (issue: EndpointIssue) => ({
    protocol: null,
    root: false,
    issue,
  });
  if (!address) return { protocol: null, root: false, issue: null };
  if (
    /[\x00-\x20\x7f\\?#]/u.test(address) ||
    /^[a-z][a-z0-9+.-]*:\/\/[^/?#]*@/iu.test(address)
  )
    return invalid("address");
  let url: URL;
  try {
    url = new URL(address);
  } catch {
    return invalid("address");
  }
  if (url.username || url.password || url.search || url.hash)
    return invalid("address");
  if (
    url.protocol !== "https:" &&
    !(
      url.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    )
  )
    return invalid("secure");
  const path = url.pathname;
  for (const protocol of [
    "openai_chat_completions",
    "openai_responses",
    "anthropic_messages",
  ] as const) {
    if (path.endsWith(requestPaths[protocol]))
      return { protocol, root: false, issue: null };
  }
  if (path === "/" || path === "")
    return { protocol: null, root: true, issue: null };
  return invalid("path");
}
export function protocolFromEndpoint(value: string): Protocol | null {
  return inspectModelEndpoint(value).protocol;
}
