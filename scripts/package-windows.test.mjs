import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  innoSetupCompilerCandidates,
  parseInnoSetupCompilerMajor,
  parseInnoSetupRegistryInstallLocation,
  readPortableExecutableSubsystem,
  resolveInnoSetupCompiler,
  verifyWindowsInstaller,
  verifyWindowsRuntimeStage,
  windowsFileVersion,
  windowsInstallerArtifactName,
} from "./package-windows.mjs";

function guiExecutableBytes(size = 512) {
  const bytes = Buffer.alloc(size);
  bytes.write("MZ", 0, "ascii");
  bytes.writeUInt32LE(0x80, 0x3c);
  bytes.write("PE\0\0", 0x80, "ascii");
  const optionalHeaderOffset = 0x80 + 24;
  bytes.writeUInt16LE(0x20b, optionalHeaderOffset);
  bytes.writeUInt16LE(2, optionalHeaderOffset + 68);
  return bytes;
}

test("Windows installer name is derived from app.zon", () => {
  assert.equal(
    windowsInstallerArtifactName,
    "metawork-0.1.1-windows-x64-setup.exe",
  );
  assert.equal(windowsFileVersion("0.1.1"), "0.1.1.0");
  assert.equal(windowsFileVersion("1.2.3-beta.1"), "1.2.3.0");
  assert.throws(() => windowsFileVersion("1.70000.3"), /65535/u);
});

test("Native package consumes prebuilt platform icons", () => {
  const manifest = readFileSync(new URL("../app.zon", import.meta.url), "utf8");
  const iconDeclaration = manifest.match(
    /\.icons = \.\{(?<icons>[\s\S]*?)\n\s*\},/u,
  );
  assert.ok(iconDeclaration?.groups);
  assert.match(iconDeclaration.groups.icons, /"assets\/icons\/app-icon\.png"/u);
  assert.match(
    iconDeclaration.groups.icons,
    /"assets\/icons\/app-icon\.icns"/u,
  );
  assert.match(iconDeclaration.groups.icons, /"assets\/icons\/app-icon\.ico"/u);
  assert.doesNotMatch(iconDeclaration.groups.icons, /app-icon\.svg/u);

  const ico = readFileSync(
    new URL("../assets/icons/app-icon.ico", import.meta.url),
  );
  assert.deepEqual(ico.subarray(0, 4), Buffer.from([0, 0, 1, 0]));
  const icns = readFileSync(
    new URL("../assets/icons/app-icon.icns", import.meta.url),
  );
  assert.equal(icns.subarray(0, 4).toString("ascii"), "icns");
});

test("Inno Setup compiler discovery prefers an explicit absolute path", () => {
  const explicit = path.resolve("C:/toolchains/inno/ISCC.exe");
  const environment = {
    METAWORK_INNO_SETUP_COMPILER: explicit,
    LOCALAPPDATA: path.resolve("C:/Users/test/AppData/Local"),
    ProgramFiles: path.resolve("C:/Program Files"),
    Path: path.resolve("C:/Tools"),
  };
  assert.equal(innoSetupCompilerCandidates(environment)[0], explicit);
  assert.equal(
    resolveInnoSetupCompiler(
      environment,
      (candidate) => candidate === explicit,
      [],
    ),
    explicit,
  );
  assert.throws(
    () =>
      innoSetupCompilerCandidates({
        METAWORK_INNO_SETUP_COMPILER: "relative/ISCC.exe",
      }),
    /must be an absolute path/u,
  );
});

test("Inno Setup compiler gate accepts the supported 6 and 7 families", () => {
  assert.equal(
    parseInnoSetupCompilerMajor("Inno Setup 6 Command-Line Compiler"),
    6,
  );
  assert.equal(
    parseInnoSetupCompilerMajor("Inno Setup 7 Command-Line Compiler"),
    7,
  );
  assert.throws(
    () => parseInnoSetupCompilerMajor("unknown compiler"),
    /supported Inno Setup/u,
  );
});

test("Inno Setup registry discovery reads a nonstandard install drive", () => {
  assert.equal(
    parseInnoSetupRegistryInstallLocation(
      "    InstallLocation    REG_SZ    D:\\Inno Setup 6\\\r\n",
    ),
    "D:\\Inno Setup 6\\",
  );
  assert.equal(
    parseInnoSetupRegistryInstallLocation("missing value"),
    undefined,
  );
});

test("Windows runtime gate requires the Native release package and GUI executable", () => {
  const root = mkdtempSync(path.join(tmpdir(), "metawork-windows-package-"));
  try {
    for (const directory of [
      path.join(root, "bin"),
      path.join(root, "resources", "frontend", "dist"),
    ]) {
      mkdirSync(directory, { recursive: true });
    }
    writeFileSync(path.join(root, "bin", "metawork.exe"), guiExecutableBytes());
    writeFileSync(path.join(root, "bin", "WebView2Loader.dll"), "loader");
    writeFileSync(path.join(root, "app-icon.ico"), "icon");
    writeFileSync(
      path.join(root, "resources", "frontend", "dist", "index.html"),
      "<main></main>",
    );
    writeFileSync(
      path.join(root, "resources", "frontend", "dist", "asset-manifest.zon"),
      ".{}",
    );
    writeFileSync(
      path.join(root, "package-manifest.zon"),
      `.{
  .target = "windows",
  .version = "0.1.1",
  .app_id = "com.metask.metawork.dev",
  .executable = "metawork.exe",
  .optimize = "ReleaseFast",
  .subsystem = "gui",
}`,
    );
    verifyWindowsRuntimeStage(root, {
      identity: {
        bundleId: "com.metask.metawork.dev",
        executableName: "metawork",
      },
      metadata: { displayName: "MetaWork", version: "0.1.1" },
    });
    assert.equal(
      readPortableExecutableSubsystem(path.join(root, "bin", "metawork.exe")),
      2,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("standalone installer gate requires a nontrivial PE artifact", () => {
  const root = mkdtempSync(path.join(tmpdir(), "metawork-windows-installer-"));
  try {
    const installerPath = path.join(root, "metawork-setup.exe");
    writeFileSync(installerPath, guiExecutableBytes(100_001));
    assert.match(verifyWindowsInstaller(installerPath), /^[0-9a-f]{64}$/u);
    writeFileSync(installerPath, "not an installer");
    assert.throws(
      () => verifyWindowsInstaller(installerPath),
      /standalone EXE/u,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
