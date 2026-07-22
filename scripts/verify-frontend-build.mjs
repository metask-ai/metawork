import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { cspPlaceholder, releaseCsp } from "../frontend/csp.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const indexPath = path.join(repositoryRoot, "frontend", "dist", "index.html");
const html = await readFile(indexPath, "utf8");

const requiredCsp = `content="${releaseCsp}"`;
if (!html.includes(requiredCsp)) {
  throw new Error(
    `production index does not contain the required CSP: ${indexPath}`,
  );
}

const forbiddenTokens = [
  cspPlaceholder,
  "127.0.0.1",
  "localhost",
  "ws://",
  "'unsafe-inline'",
];
for (const token of forbiddenTokens) {
  if (html.includes(token)) {
    throw new Error(
      `production index contains forbidden token ${token}: ${indexPath}`,
    );
  }
}

const assetsPath = path.join(repositoryRoot, "frontend", "dist", "assets");
const assets = await readdir(assetsPath);
const styleText = (
  await Promise.all(
    assets
      .filter((name) => name.endsWith(".css"))
      .map((name) => readFile(path.join(assetsPath, name), "utf8")),
  )
).join("\n");
if (styleText.includes("@media (width<="))
  throw new Error(
    "production CSS contains media-query range syntax unsupported by the macOS 13.0 baseline",
  );
for (const query of [1100, 819, 560]) {
  if (!styleText.includes(`@media (max-width:${query}px)`))
    throw new Error(
      `production CSS is missing the ${query}px responsive query`,
    );
}
console.log("verified production Renderer CSP");
