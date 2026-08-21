import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, rmSync, statSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

import { buildFrontend, nativeCli, repositoryRoot } from "./build.mjs";
import { readNativePackageManifest } from "./package-metadata.mjs";
import { runChild } from "./run-child-process.mjs";
import { verifyNativeAutomationIsolation } from "./verify-native-automation-isolation.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";

const packageManifest = readNativePackageManifest(repositoryRoot);

export const windowsRuntimeStagePath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  "windows-runtime-x64",
);
export const windowsReleaseBuildPath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  "windows-release-build",
);
export const windowsInstallerArtifactName = `${packageManifest.identity.executableName}-${packageManifest.metadata.version}-windows-x64-setup.exe`;
export const windowsInstallerArtifactPath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  windowsInstallerArtifactName,
);

export function windowsFileVersion(version) {
  const match = version.match(/^(\d+)\.(\d+)\.(\d+)/u);
  if (!match) throw new Error("Windows file version requires semver metadata");
  const components = match.slice(1).map(Number);
  if (components.some((component) => component > 65_535)) {
    throw new Error("Windows file version components must not exceed 65535");
  }
  return `${components.join(".")}.0`;
}

function uniquePaths(paths) {
  const seen = new Set();
  return paths.filter((candidate) => {
    if (!candidate) return false;
    const key = path.resolve(candidate).toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function innoSetupCompilerCandidates(environment = process.env) {
  const explicit = environment.METAWORK_INNO_SETUP_COMPILER;
  if (explicit && !path.isAbsolute(explicit)) {
    throw new Error("METAWORK_INNO_SETUP_COMPILER must be an absolute path");
  }
  const installed = [];
  for (const root of [
    environment.LOCALAPPDATA && path.join(environment.LOCALAPPDATA, "Programs"),
    environment.ProgramFiles,
    environment["ProgramFiles(x86)"],
  ]) {
    if (!root) continue;
    installed.push(
      path.join(root, "Inno Setup 7", "ISCC.exe"),
      path.join(root, "Inno Setup 6", "ISCC.exe"),
    );
  }
  const fromPath = (environment.Path ?? environment.PATH ?? "")
    .split(path.delimiter)
    .filter(Boolean)
    .map((entry) => path.join(entry, "ISCC.exe"));
  return uniquePaths([explicit, ...installed, ...fromPath]);
}

export function parseInnoSetupRegistryInstallLocation(output) {
  return output.match(/^\s*InstallLocation\s+REG_\w+\s+(.+?)\s*$/imu)?.[1];
}

export function innoSetupRegistryCompilerCandidates(
  environment = process.env,
  query = spawnSync,
) {
  if (!environment.SystemRoot) return [];
  const registry = path.join(environment.SystemRoot, "System32", "reg.exe");
  const keys = [];
  for (const hive of ["HKCU", "HKLM"]) {
    for (const version of [7, 6]) {
      keys.push(
        `${hive}\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Inno Setup ${version}_is1`,
      );
      if (hive === "HKLM") {
        keys.push(
          `${hive}\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Inno Setup ${version}_is1`,
        );
      }
    }
  }
  const candidates = [];
  for (const key of keys) {
    const result = query(registry, ["query", key, "/v", "InstallLocation"], {
      encoding: "utf8",
      stdio: "pipe",
      windowsHide: true,
    });
    if (result.error || result.status !== 0) continue;
    const installLocation = parseInnoSetupRegistryInstallLocation(
      `${result.stdout ?? ""}${result.stderr ?? ""}`,
    );
    if (installLocation)
      candidates.push(path.join(installLocation, "ISCC.exe"));
  }
  return uniquePaths(candidates);
}

export function resolveInnoSetupCompiler(
  environment = process.env,
  isFile = (candidate) => {
    try {
      return existsSync(candidate) && statSync(candidate).isFile();
    } catch {
      return false;
    }
  },
  registryCandidates = innoSetupRegistryCompilerCandidates(environment),
) {
  const compiler = uniquePaths([
    ...innoSetupCompilerCandidates(environment),
    ...registryCandidates,
  ]).find(isFile);
  if (!compiler) {
    throw new Error(
      "Inno Setup 6.7.3 or a compatible 7.x compiler is required. Install it with winget, or set METAWORK_INNO_SETUP_COMPILER to an absolute ISCC.exe path.",
    );
  }
  return compiler;
}

export function parseInnoSetupCompilerMajor(output) {
  const major = Number(
    output.match(/^Inno Setup (\d+) .*Command-Line Compiler\s*$/imu)?.[1],
  );
  if (major !== 6 && major !== 7) {
    throw new Error("ISCC.exe is not a supported Inno Setup 6 or 7 compiler");
  }
  return major;
}

export function verifyInnoSetupCompiler(compiler) {
  const result = spawnSync(compiler, ["/?"], {
    cwd: repositoryRoot,
    encoding: "utf8",
    stdio: "pipe",
    windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`ISCC.exe /? failed with exit code ${result.status}`);
  }
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  const major = parseInnoSetupCompilerMajor(output);
  const requiredOptions =
    major === 7
      ? [
          "--output-dir=<path>",
          "--output-filename=<filename>",
          "--quiet-progress",
          "--define=<name>",
        ]
      : ["/O<path>", "/F<filename>", "/Qp", "/D<name>"];
  for (const requiredOption of requiredOptions) {
    if (!output.includes(requiredOption)) {
      throw new Error(
        `ISCC.exe help is missing required option ${requiredOption}`,
      );
    }
  }
  return major;
}

export function readPortableExecutableSubsystem(executablePath) {
  const bytes = readFileSync(executablePath);
  if (bytes.length < 0x40 || bytes.toString("ascii", 0, 2) !== "MZ") {
    throw new Error(`${executablePath} is not a PE executable`);
  }
  const peOffset = bytes.readUInt32LE(0x3c);
  const optionalHeaderOffset = peOffset + 24;
  if (
    optionalHeaderOffset + 70 > bytes.length ||
    bytes.toString("ascii", peOffset, peOffset + 4) !== "PE\0\0"
  ) {
    throw new Error(`${executablePath} has an invalid PE header`);
  }
  const magic = bytes.readUInt16LE(optionalHeaderOffset);
  if (magic !== 0x10b && magic !== 0x20b) {
    throw new Error(`${executablePath} has an unsupported PE optional header`);
  }
  return bytes.readUInt16LE(optionalHeaderOffset + 68);
}

function requireRegularFile(filePath) {
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    throw new Error(`Windows runtime package is missing ${filePath}`);
  }
}

export function verifyWindowsRuntimeStage(
  stagePath = windowsRuntimeStagePath,
  manifest = packageManifest,
) {
  const executablePath = path.join(
    stagePath,
    "bin",
    `${manifest.identity.executableName}.exe`,
  );
  for (const relativePath of [
    path.join("bin", "WebView2Loader.dll"),
    "app-icon.ico",
    "package-manifest.zon",
    path.join("resources", "frontend", "dist", "index.html"),
    path.join("resources", "frontend", "dist", "asset-manifest.zon"),
  ]) {
    requireRegularFile(path.join(stagePath, relativePath));
  }
  requireRegularFile(executablePath);
  if (readPortableExecutableSubsystem(executablePath) !== 2) {
    throw new Error(
      "Windows runtime package does not contain a GUI-subsystem executable",
    );
  }
  const nativeManifest = readFileSync(
    path.join(stagePath, "package-manifest.zon"),
    "utf8",
  );
  for (const expected of [
    `.target = "windows"`,
    `.version = "${manifest.metadata.version}"`,
    `.app_id = "${manifest.identity.bundleId}"`,
    `.executable = "${manifest.identity.executableName}.exe"`,
    `.optimize = "ReleaseFast"`,
    `.subsystem = "gui"`,
  ]) {
    if (!nativeManifest.includes(expected)) {
      throw new Error(`Windows package manifest is missing ${expected}`);
    }
  }
}

export function verifyWindowsInstaller(installerPath) {
  requireRegularFile(installerPath);
  const bytes = readFileSync(installerPath);
  if (
    bytes.length < 100_000 ||
    bytes.toString("ascii", 0, 2) !== "MZ" ||
    readPortableExecutableSubsystem(installerPath) !== 2
  ) {
    throw new Error("Windows installer is not a valid standalone EXE artifact");
  }
  return createHash("sha256").update(bytes).digest("hex");
}

async function packageWindows() {
  if (process.platform !== "win32") {
    throw new Error("package:windows must run on Windows");
  }
  const compiler = resolveInnoSetupCompiler();
  const compilerMajor = verifyInnoSetupCompiler(compiler);

  const bundle = await verifyStagedAgentCoreBundle(repositoryRoot);
  await buildFrontend(repositoryRoot);
  rmSync(windowsReleaseBuildPath, { recursive: true, force: true });
  await runChild(
    "zig",
    [
      "build",
      `-Dtarget=${bundle.target}`,
      "-Doptimize=ReleaseFast",
      "--prefix",
      windowsReleaseBuildPath,
    ],
    {
      cwd: repositoryRoot,
      label: "Isolated Windows ReleaseFast build",
      timeoutMs: null,
    },
  );
  const releaseExecutablePath = path.join(
    windowsReleaseBuildPath,
    "bin",
    `${packageManifest.identity.executableName}.exe`,
  );
  await verifyNativeAutomationIsolation(releaseExecutablePath);

  rmSync(windowsRuntimeStagePath, { recursive: true, force: true });
  rmSync(windowsInstallerArtifactPath, { force: true });
  await runChild(
    process.execPath,
    [
      nativeCli,
      "package",
      "--target",
      "windows",
      "--output",
      windowsRuntimeStagePath,
      "--binary",
      releaseExecutablePath,
      "--assets",
      path.join(repositoryRoot, "frontend", "dist"),
    ],
    {
      cwd: repositoryRoot,
      label: "Native SDK Windows runtime package",
      timeoutMs: null,
    },
  );
  verifyWindowsRuntimeStage();

  const installerStem = windowsInstallerArtifactName.slice(0, -".exe".length);
  const definitions = [
    `AppVersion=${packageManifest.metadata.version}`,
    `AppDisplayName=${packageManifest.metadata.displayName}`,
    `AppExecutableName=${packageManifest.identity.executableName}`,
    `AppFileVersion=${windowsFileVersion(packageManifest.metadata.version)}`,
  ];
  const compilerArguments =
    compilerMajor === 7
      ? [
          "--quiet-progress",
          `--output-dir=${path.dirname(windowsInstallerArtifactPath)}`,
          `--output-filename=${installerStem}`,
          ...definitions.map((definition) => `--define=${definition}`),
        ]
      : [
          "/Qp",
          `/O${path.dirname(windowsInstallerArtifactPath)}`,
          `/F${installerStem}`,
          ...definitions.map((definition) => `/D${definition}`),
        ];
  await runChild(
    compiler,
    [
      ...compilerArguments,
      path.join(repositoryRoot, "packaging", "windows", "metawork.iss"),
    ],
    {
      cwd: repositoryRoot,
      label: "Inno Setup Windows installer",
      timeoutMs: null,
    },
  );
  const digest = verifyWindowsInstaller(windowsInstallerArtifactPath);
  console.log(
    `built unsigned Windows installer with Inno Setup ${compilerMajor}: ${windowsInstallerArtifactPath} (sha256=${digest})`,
  );
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : null;
if (invokedPath === import.meta.url) {
  try {
    await packageWindows();
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
