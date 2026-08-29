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
  defaultWindowsTimestampUrl,
  innoSignToolCompilerArgument,
  innoSetupCompilerCandidates,
  parseInnoSetupCompilerMajor,
  parseInnoSetupRegistryInstallLocation,
  parseWindowsPackageArguments,
  readPortableExecutableMachine,
  readPortableExecutableSubsystem,
  resolveInnoSetupCompiler,
  resolveWindowsSignTool,
  verifyWindowsInstaller,
  verifyWindowsRuntimeStage,
  windowsFileVersion,
  windowsDistributionForArchitecture,
  windowsSignArguments,
  windowsSigningConfiguration,
  windowsSignToolCandidates,
  windowsVerifyArguments,
} from "./package-windows.mjs";

function guiExecutableBytes(size = 512, machine = 0x8664) {
  const bytes = Buffer.alloc(size);
  bytes.write("MZ", 0, "ascii");
  bytes.writeUInt32LE(0x80, 0x3c);
  bytes.write("PE\0\0", 0x80, "ascii");
  bytes.writeUInt16LE(machine, 0x80 + 4);
  const optionalHeaderOffset = 0x80 + 24;
  bytes.writeUInt16LE(0x20b, optionalHeaderOffset);
  bytes.writeUInt16LE(2, optionalHeaderOffset + 68);
  return bytes;
}

test("Windows distributions derive exact target and artifact identities", () => {
  const x64 = windowsDistributionForArchitecture("x64");
  const arm64 = windowsDistributionForArchitecture("arm64");
  assert.equal(x64.targetId, "x86_64-windows-gnu");
  assert.equal(x64.peMachine, 0x8664);
  assert.equal(x64.innoArchitecture, "x64compatible");
  assert.equal(x64.installerArtifactName, "metawork-0.1.5-windows-x64.exe");
  assert.equal(arm64.targetId, "aarch64-windows-gnu");
  assert.equal(arm64.peMachine, 0xaa64);
  assert.equal(arm64.innoArchitecture, "arm64");
  assert.equal(arm64.installerArtifactName, "metawork-0.1.5-windows-arm64.exe");
  assert.throws(
    () => windowsDistributionForArchitecture("x86"),
    /expected x64 or arm64/u,
  );
  assert.equal(windowsFileVersion("0.1.1"), "0.1.1.0");
  assert.equal(windowsFileVersion("1.2.3-beta.1"), "1.2.3.0");
  assert.throws(() => windowsFileVersion("1.70000.3"), /65535/u);
});

test("Native package consumes only shared PNG and the prebuilt Windows icon", () => {
  const manifest = readFileSync(new URL("../app.zon", import.meta.url), "utf8");
  const iconDeclaration = manifest.match(
    /\.icons = \.\{(?<icons>[\s\S]*?)\n\s*\},/u,
  );
  assert.ok(iconDeclaration?.groups);
  assert.match(iconDeclaration.groups.icons, /"assets\/icons\/app-icon\.png"/u);
  assert.match(iconDeclaration.groups.icons, /"assets\/icons\/app-icon\.ico"/u);
  assert.doesNotMatch(iconDeclaration.groups.icons, /app-icon\.svg/u);
  assert.doesNotMatch(iconDeclaration.groups.icons, /app-icon\.icns/u);
  assert.doesNotMatch(iconDeclaration.groups.icons, /MetaWork\.icon/u);

  const ico = readFileSync(
    new URL("../assets/icons/app-icon.ico", import.meta.url),
  );
  assert.deepEqual(ico.subarray(0, 4), Buffer.from([0, 0, 1, 0]));
});

test("Windows application icon is embedded and assigned to installed shortcuts", () => {
  const build = readFileSync(new URL("../build.zig", import.meta.url), "utf8");
  assert.match(build, /addWin32ResourceFile/u);
  assert.match(build, /packaging\/windows\/metawork\.rc/u);
  assert.match(build, /include_paths = &\.\{b\.path\("assets\/icons"\)\}/u);

  const resource = readFileSync(
    new URL("../packaging/windows/metawork.rc", import.meta.url),
    "utf8",
  );
  assert.match(resource, /^#define IDI_METAWORK 1$/mu);
  assert.match(resource, /^IDI_METAWORK ICON "app-icon\.ico"$/mu);

  const installer = readFileSync(
    new URL("../packaging/windows/metawork.iss", import.meta.url),
    "utf8",
  );
  assert.match(installer, /^SetupIconFile=.*app-icon\.ico$/mu);
  assert.match(installer, /^UninstallDisplayIcon=.*app-icon\.ico$/mu);
  assert.match(installer, /^ArchitecturesAllowed=\{#AppArchitecture\}$/mu);
  assert.match(
    installer,
    /^ArchitecturesInstallIn64BitMode=\{#AppArchitecture\}$/mu,
  );
  const shortcuts = installer
    .split(/\r?\n/u)
    .filter((line) => line.startsWith('Name: "{auto'));
  assert.equal(shortcuts.length, 2);
  for (const shortcut of shortcuts) {
    assert.match(shortcut, /IconFilename: "\{app\}\\app-icon\.ico"/u);
  }
});

test("Windows installer closes the old Host before replacement and does not restart it", () => {
  const installer = readFileSync(
    new URL("../packaging/windows/metawork.iss", import.meta.url),
    "utf8",
  );
  assert.match(installer, /^CloseApplications=yes$/mu);
  assert.match(installer, /^RestartApplications=no$/mu);
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

test("signed packaging is explicit and fail closed", () => {
  assert.deepEqual(parseWindowsPackageArguments([]), {
    architecture: "x64",
    signing: "none",
  });
  assert.deepEqual(parseWindowsPackageArguments(["arm64"]), {
    architecture: "arm64",
    signing: "none",
  });
  assert.deepEqual(parseWindowsPackageArguments(["--signing", "required"]), {
    architecture: "x64",
    signing: "required",
  });
  assert.deepEqual(
    parseWindowsPackageArguments(["arm64", "--signing=required"]),
    { architecture: "arm64", signing: "required" },
  );
  assert.throws(
    () => parseWindowsPackageArguments(["--signing", "auto"]),
    /none or required/u,
  );
  assert.throws(
    () => parseWindowsPackageArguments(["--certificate", "subject"]),
    /unknown/u,
  );
  assert.throws(
    () =>
      parseWindowsPackageArguments(["--signing=none", "--signing=required"]),
    /only be specified once/u,
  );
  assert.throws(
    () => parseWindowsPackageArguments(["x64", "arm64"]),
    /architecture may only be specified once/u,
  );
});

test("Windows SDK SignTool discovery prefers an explicit path then the newest x64 kit", () => {
  const explicit = path.resolve("C:/Tools/Windows SDK/signtool.exe");
  const environment = {
    "ProgramFiles(x86)": path.resolve("C:/Program Files (x86)"),
    METAWORK_WINDOWS_SIGNTOOL: explicit,
  };
  const candidates = windowsSignToolCandidates(environment, () => [
    { name: "10.0.22621.0", isDirectory: () => true },
    { name: "10.0.26100.0", isDirectory: () => true },
    { name: "not-a-version", isDirectory: () => true },
  ]);
  assert.equal(candidates[0], explicit);
  assert.match(candidates[1], /10\.0\.26100\.0[\\/]x64[\\/]signtool\.exe$/u);
  assert.equal(
    resolveWindowsSignTool(
      environment,
      (candidate) => candidate === candidates[1],
      candidates,
    ),
    candidates[1],
  );
  assert.throws(
    () =>
      windowsSignToolCandidates({ METAWORK_WINDOWS_SIGNTOOL: "relative.exe" }),
    /absolute path/u,
  );
});

test("modern SignTool arguments pin identity, SHA-256, RFC 3161, and verification policy", () => {
  const signTool = path.resolve("C:/Windows Kits/10/x64/signtool.exe");
  const certificateSha1 = "0123456789abcdef0123456789abcdef01234567";
  const configuration = windowsSigningConfiguration(
    { signing: "required" },
    {
      METAWORK_WINDOWS_SIGNING_CERTIFICATE_SHA1: certificateSha1,
    },
    signTool,
  );
  assert.deepEqual(configuration, {
    certificateSha1: certificateSha1.toUpperCase(),
    signTool,
    timestampUrl: `${defaultWindowsTimestampUrl}/`,
  });
  assert.deepEqual(windowsSignArguments(configuration, "MetaWork.exe"), [
    "sign",
    "/sha1",
    certificateSha1.toUpperCase(),
    "/fd",
    "SHA256",
    "/tr",
    `${defaultWindowsTimestampUrl}/`,
    "/td",
    "SHA256",
    "/d",
    "MetaWork",
    "/v",
    "MetaWork.exe",
  ]);
  assert.deepEqual(windowsVerifyArguments("MetaWork.exe"), [
    "verify",
    "/pa",
    "/all",
    "/v",
    "MetaWork.exe",
  ]);
  assert.match(
    innoSignToolCompilerArgument(7, configuration),
    /^--signtool=metawork=\$q.*signtool\.exe\$q sign \/sha1 .*\/fd SHA256 .*\/tr \$q.*\$q .*\/td SHA256 .*\$f$/u,
  );
  assert.match(
    innoSignToolCompilerArgument(6, configuration),
    /^\/Smetawork=/u,
  );
  const innoScript = readFileSync(
    new URL("../packaging/windows/metawork.iss", import.meta.url),
    "utf8",
  );
  assert.match(innoScript, /#ifdef AppSignTool/u);
  assert.match(innoScript, /^SignTool=\{#AppSignTool\}$/mu);
  assert.match(innoScript, /^SignedUninstaller=yes$/mu);
  assert.throws(
    () =>
      windowsSigningConfiguration(
        { signing: "required" },
        { METAWORK_WINDOWS_SIGNING_CERTIFICATE_SHA1: "not-a-thumbprint" },
        signTool,
      ),
    /40-digit/u,
  );
  assert.equal(windowsSigningConfiguration({ signing: "none" }, {}), null);
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
    writeFileSync(
      path.join(root, "bin", "WebView2Loader.dll"),
      guiExecutableBytes(512, 0x8664),
    );
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
    const distribution = windowsDistributionForArchitecture("x64");
    const manifest = {
      identity: {
        bundleId: "com.metask.metawork.dev",
        executableName: "metawork",
      },
      metadata: { displayName: "MetaWork", version: "0.1.1" },
    };
    verifyWindowsRuntimeStage(root, distribution, manifest);
    assert.equal(
      readPortableExecutableSubsystem(path.join(root, "bin", "metawork.exe")),
      2,
    );
    assert.equal(
      readPortableExecutableMachine(path.join(root, "bin", "metawork.exe")),
      0x8664,
    );
    writeFileSync(
      path.join(root, "bin", "WebView2Loader.dll"),
      guiExecutableBytes(512, 0xaa64),
    );
    assert.throws(
      () => verifyWindowsRuntimeStage(root, distribution, manifest),
      /WebView2 loader PE machine/u,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("standalone installer gate requires a nontrivial PE artifact", () => {
  const root = mkdtempSync(path.join(tmpdir(), "metawork-windows-installer-"));
  try {
    const installerPath = path.join(root, "metawork-installer.exe");
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
