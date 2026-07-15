import { readFile } from "node:fs/promises";
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

console.log("verified production Renderer CSP");
