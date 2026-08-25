import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  macosAppIconName,
  macosIconActoolArguments,
  parseActoolVersionReport,
  requireSupportedActoolVersion,
  stageMacosAppIcon,
  validateMacosIconComposerSource,
  verifyStagedMacosAppIcon,
} from "./native-sdk-compat/macos-icon-composer.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

function digest(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

test("macOS Icon Composer source is the flat canonical app icon", () => {
  const sourcePath = path.join(
    repositoryRoot,
    "assets",
    "icons",
    "MetaWork.icon",
  );
  const canonicalPngPath = path.join(
    repositoryRoot,
    "assets",
    "icons",
    "app-icon.png",
  );
  const validated = validateMacosIconComposerSource(
    sourcePath,
    canonicalPngPath,
  );
  assert.equal(validated.sourcePath, sourcePath);
  assert.deepEqual(
    readFileSync(validated.iconAssetPath),
    readFileSync(canonicalPngPath),
  );
  const manifest = JSON.parse(readFileSync(validated.iconJsonPath, "utf8"));
  assert.deepEqual(manifest.fill, {
    solid: "extended-gray:1.00000,1.00000",
  });
  assert.equal(manifest.groups[0].layers[0].glass, false);
  assert.equal(manifest.groups[0].shadow.kind, "none");
  assert.equal(manifest.groups[0].specular, false);
  assert.equal(manifest.groups[0].translucency.enabled, false);
});

test("macOS Icon Composer packaging pins the reviewed actool compiler", () => {
  const report = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.actool.version</key><dict>
<key>bundle-version</key><string>24765</string>
<key>short-bundle-version</key><string>26.6</string>
</dict></dict></plist>`;
  assert.deepEqual(parseActoolVersionReport(report), {
    bundleVersion: "24765",
    shortVersion: "26.6",
  });
  assert.deepEqual(
    requireSupportedActoolVersion(parseActoolVersionReport(report)),
    { bundleVersion: "24765", shortVersion: "26.6" },
  );
  assert.throws(
    () =>
      requireSupportedActoolVersion({
        bundleVersion: "99999",
        shortVersion: "27.0",
      }),
    /unsupported actool 27\.0/u,
  );
  assert.throws(
    () => parseActoolVersionReport("not a plist"),
    /missing typed version fields/u,
  );
});

test("macOS Icon Composer compile arguments are a closed macOS-only contract", () => {
  assert.deepEqual(
    macosIconActoolArguments("/source/MetaWork.icon", "/output"),
    [
      "actool",
      "/source/MetaWork.icon",
      "--compile",
      "/output",
      "--app-icon",
      "MetaWork",
      "--enable-on-demand-resources",
      "NO",
      "--development-region",
      "en",
      "--target-device",
      "mac",
      "--platform",
      "macosx",
      "--include-all-app-icons",
      "--minimum-deployment-target",
      "11.0",
      "--output-partial-info-plist",
      "/output/partial.plist",
      "--output-format",
      "human-readable-text",
    ],
  );
});

test(
  "macOS Icon Composer resources replace the Native SDK fallback before signing",
  { skip: process.platform !== "darwin" },
  async () => {
    const root = await mkdtemp(path.join(tmpdir(), "metawork-app-icon-stage-"));
    try {
      const artifactRoot = path.join(root, "artifact");
      const appPath = path.join(root, "MetaWork.app");
      const contentsPath = path.join(appPath, "Contents");
      const resourcesPath = path.join(contentsPath, "Resources");
      mkdirSync(artifactRoot, { recursive: true });
      mkdirSync(resourcesPath, { recursive: true });

      const assetCatalogPath = path.join(artifactRoot, "Assets.car");
      const fallbackIconPath = path.join(artifactRoot, "MetaWork.icns");
      writeFileSync(assetCatalogPath, Buffer.from("BOMStorefixture"));
      writeFileSync(fallbackIconPath, Buffer.from("icnsfixture"));
      writeFileSync(
        path.join(resourcesPath, "AppIcon.icns"),
        Buffer.from("icnsnative-sdk"),
      );
      writeFileSync(
        path.join(contentsPath, "Info.plist"),
        `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
</dict></plist>`,
      );
      const artifact = {
        assetCatalogDigest: digest(assetCatalogPath),
        assetCatalogPath,
        fallbackIconDigest: digest(fallbackIconPath),
        fallbackIconPath,
        outputPath: artifactRoot,
      };

      const staged = stageMacosAppIcon(artifact, appPath);
      assert.equal(path.basename(staged.assetCatalogPath), "Assets.car");
      assert.equal(path.basename(staged.fallbackIconPath), "MetaWork.icns");
      assert.equal(existsSync(path.join(resourcesPath, "AppIcon.icns")), false);
      assert.deepEqual(verifyStagedMacosAppIcon(artifact, appPath), staged);
      assert.equal(macosAppIconName, "MetaWork");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
);
