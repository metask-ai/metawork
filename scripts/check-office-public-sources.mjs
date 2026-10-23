// Developer qualification only. This neither installs resources nor grants the
// desktop client new download authority. Hash the actual GET body; HEAD lengths
// can describe HTTP compression and are not artifact identity evidence.
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  officePublicDownloads,
  queryOfficeAuthoring,
} from "./office-component-sources.mjs";

export async function fetchOfficeSource(
  url,
  { signal, fetchSource = fetch } = {},
) {
  const valid = (value) => {
    const parsed = new URL(value);
    if (
      parsed.protocol !== "https:" ||
      parsed.username ||
      parsed.password ||
      parsed.search ||
      parsed.hash
    )
      throw Error("Invalid pinned Office public source");
    return parsed;
  };
  const origin = valid(url);
  const archive =
    origin.origin === "https://downloadarchive.documentfoundation.org" &&
    origin.pathname.startsWith("/libreoffice/old/");
  for (let hops = 0; ; hops++) {
    valid(url);
    const response = await fetchSource(url, {
      redirect: archive ? "manual" : "error",
      headers: { "Accept-Encoding": "identity" },
      signal,
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      await response.body?.cancel();
      if (!archive || hops >= 3 || !location)
        throw Error("Office source did not return a direct complete body");
      valid(location);
      url = location;
      continue;
    }
    if (response.redirected) {
      await response.body?.cancel();
      throw Error("Office source did not return a direct complete body");
    }
    return response;
  }
}

export async function verifyPinnedDownload(item, fetchSource = fetch) {
  const url = new URL(item.url);
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !["sha256", "sha512"].includes(item.algorithm) ||
    !new RegExp(
      `^[a-f0-9]{${item.algorithm === "sha256" ? 64 : 128}}$`,
      "u",
    ).test(item.digest) ||
    (item.bytes !== null &&
      (!Number.isSafeInteger(item.bytes) ||
        item.bytes <= 0 ||
        item.bytes > 512 * 1024 * 1024))
  )
    throw new Error("Invalid pinned Office public source");
  const response = await fetchOfficeSource(item.url, {
    fetchSource,
    signal: AbortSignal.timeout(180000),
  });
  if (response.status !== 200 || response.redirected || !response.body) {
    await response.body?.cancel();
    throw new Error(
      `Office source did not return a direct complete body: ${response.status}`,
    );
  }
  const hash = createHash(item.algorithm);
  let bytes = 0;
  for await (const chunk of response.body) {
    bytes += chunk.length;
    if (bytes > (item.bytes ?? 256 * 1024 * 1024))
      throw new Error("Office public source exceeded its byte budget");
    hash.update(chunk);
  }
  const digest = hash.digest("hex");
  if (
    bytes === 0 ||
    (item.bytes !== null && bytes !== item.bytes) ||
    digest !== item.digest
  )
    throw new Error(
      "Office public source body differs from the pinned identity",
    );
  return { ...item, bytes, verified: true };
}

async function main() {
  if (process.argv.length !== 2)
    throw new Error("Usage: node scripts/check-office-public-sources.mjs");
  const root = fileURLToPath(new URL("..", import.meta.url));
  const downloads = officePublicDownloads(root, queryOfficeAuthoring(root));
  const results = [];
  // Deliberately serial: bounded network/memory, no partial installation, and no
  // generated file gets trusted as a source lock or installed manifest.
  for (const item of downloads) {
    try {
      const result = await verifyPinnedDownload(item);
      results.push(result);
      console.log(`Verified ${item.name}: ${result.bytes} bytes`);
    } catch (error) {
      results.push({ ...item, verified: false, error: error.message });
      console.error(`Rejected ${item.name}: ${error.message}`);
    }
  }
  const passed = results.every((result) => result.verified);
  const report = {
    schema: 1,
    target: "x86_64-windows-msvc",
    checkedAt: new Date().toISOString(),
    scope:
      "public source bytes only; not client installation, signing, or clean-machine acceptance",
    passed,
    downloads: results.length,
    downloadedBytes: results
      .filter((result) => result.verified)
      .reduce((sum, result) => sum + result.bytes, 0),
    results,
  };
  mkdirSync(path.join(root, ".zig-cache"), { recursive: true });
  const output = path.join(
    root,
    ".zig-cache/office-public-source-verification.json",
  );
  writeFileSync(output, JSON.stringify(report, null, 2) + "\n");
  console.log(
    `Office public sources: ${passed ? "passed" : "FAILED"}; ${output}`,
  );
  if (!passed) process.exitCode = 1;
}

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
)
  await main();
