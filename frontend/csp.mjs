import { createHash } from "node:crypto";

export const cspPlaceholder = "__METAWORK_CSP__";

export const releaseCsp =
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'";

export function developmentCsp(html) {
  // React Fast Refresh injects an inline preamble. Permit its exact bytes
  // after Vite's HTML transforms without allowing arbitrary inline scripts.
  const hashes = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gu)]
    .map(([, script]) => script)
    .filter((script) => script.trim())
    .map(
      (script) =>
        `'sha256-${createHash("sha256").update(script).digest("base64")}'`,
    );
  return `default-src 'self'; script-src 'self' ${hashes.join(" ")}; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self' ws://127.0.0.1:5173 http://127.0.0.1:5173`;
}
