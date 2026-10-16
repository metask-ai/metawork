import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import process from "node:process";
import { cspPlaceholder, releaseCsp } from "../frontend/csp.mjs";

const defaultRepositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

export async function verifyFrontendBuild(
  repositoryRoot = defaultRepositoryRoot,
  { outDir = path.join(repositoryRoot, "frontend", "dist") } = {},
) {
  const indexPath = path.join(outDir, "index.html");
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

  const assetsPath = path.join(outDir, "assets");
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
  for (const query of [819, 619, 560]) {
    if (!styleText.includes(`@media (max-width:${query}px)`))
      throw new Error(
        `production CSS is missing the ${query}px responsive query`,
      );
  }
  console.log("verified production Renderer CSP");
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) await verifyFrontendBuild();
