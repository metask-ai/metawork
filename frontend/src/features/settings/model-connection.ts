import type { CustomProviderView, Protocol } from "../../bridge/contracts.ts";

export const providerRequestPaths: Record<Protocol, string> = {
  openai_responses: "/responses",
  openai_chat_completions: "/chat/completions",
  anthropic_messages: "/v1/messages",
  gemini_native: "",
};
export function customProviderEndpointFromBaseUrl(
  protocol: Protocol,
  value: string,
) {
  const base = value.trim().replace(/\/+$/u, "");
  const path = providerRequestPaths[protocol];
  return !path || base.endsWith(path) ? base : `${base}${path}`;
}
export function customProviderBaseUrl(provider: CustomProviderView) {
  const path = providerRequestPaths[provider.protocol];
  return path && provider.normalizedBaseUrl.endsWith(path)
    ? provider.normalizedBaseUrl.slice(0, -path.length)
    : provider.normalizedBaseUrl;
}
