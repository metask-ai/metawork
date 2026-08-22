import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
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
export const defaultWindowsTimestampUrl = "http://time.certum.pl";

export function parseWindowsPackageArguments(arguments_) {
  let signing = "none";
  let signingSeen = false;
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    let value;
    if (argument === "--signing") {
      value = arguments_[index + 1];
      index += 1;
    } else if (argument.startsWith("--signing=")) {
      value = argument.slice("--signing=".length);
    } else {
      throw new Error(`unknown package:windows argument ${argument}`);
    }
    if (signingSeen) throw new Error("--signing may only be specified once");
    signingSeen = true;
    if (value !== "none" && value !== "required") {
      throw new Error("--signing must be none or required");
    }
    signing = value;
  }
  return Object.freeze({ signing });
}

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

export function windowsSignToolCandidates(
  environment = process.env,
  readDirectory = readdirSync,
) {
  const explicit = environment.METAWORK_WINDOWS_SIGNTOOL;
  if (explicit && !path.isAbsolute(explicit)) {
    throw new Error("METAWORK_WINDOWS_SIGNTOOL must be an absolute path");
  }
  const installed = [];
  const programFilesX86 = environment["ProgramFiles(x86)"];
  if (programFilesX86) {
    const kitsBin = path.join(programFilesX86, "Windows Kits", "10", "bin");
    let entries = [];
    try {
      entries = readDirectory(kitsBin, { withFileTypes: true });
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    const versions = entries
      .filter(
        (entry) =>
          entry.isDirectory() && /^\d+(?:\.\d+){2,3}$/u.test(entry.name),
      )
      .map((entry) => entry.name)
      .sort((left, right) =>
        right.localeCompare(left, "en", { numeric: true }),
      );
    for (const version of versions) {
      installed.push(path.join(kitsBin, version, "x64", "signtool.exe"));
    }
  }
  return uniquePaths([explicit, ...installed]);
}

export function resolveWindowsSignTool(
  environment = process.env,
  isFile = (candidate) => {
    try {
      return existsSync(candidate) && statSync(candidate).isFile();
    } catch {
      return false;
    }
  },
  candidates = windowsSignToolCandidates(environment),
) {
  const signTool = candidates.find(isFile);
  if (!signTool) {
    throw new Error(
      "Windows SDK x64 signtool.exe is required for signed packaging. Install the Windows SDK or set METAWORK_WINDOWS_SIGNTOOL to its absolute path.",
    );
  }
  return signTool;
}

export function windowsSigningConfiguration(
  options,
  environment = process.env,
  signTool = options.signing === "required"
    ? resolveWindowsSignTool(environment)
    : null,
) {
  if (options.signing === "none") return null;
  const certificateSha1 = (
    environment.METAWORK_WINDOWS_SIGNING_CERTIFICATE_SHA1 ?? ""
  )
    .replaceAll(" ", "")
    .toUpperCase();
  if (!/^[0-9A-F]{40}$/u.test(certificateSha1)) {
    throw new Error(
      "METAWORK_WINDOWS_SIGNING_CERTIFICATE_SHA1 must be the exact 40-digit certificate thumbprint",
    );
  }
  const timestampUrl =
    environment.METAWORK_WINDOWS_TIMESTAMP_URL ?? defaultWindowsTimestampUrl;
  let parsedTimestamp;
  try {
    parsedTimestamp = new URL(timestampUrl);
  } catch {
    throw new Error("METAWORK_WINDOWS_TIMESTAMP_URL must be an absolute URL");
  }
  if (!["http:", "https:"].includes(parsedTimestamp.protocol)) {
    throw new Error("METAWORK_WINDOWS_TIMESTAMP_URL must use HTTP or HTTPS");
  }
  return Object.freeze({
    certificateSha1,
    signTool,
    timestampUrl: parsedTimestamp.href,
  });
}

export function windowsSignArguments(configuration, filePath) {
  return [
    "sign",
    "/sha1",
    configuration.certificateSha1,
    "/fd",
    "SHA256",
    "/tr",
    configuration.timestampUrl,
    "/td",
    "SHA256",
    "/d",
    packageManifest.metadata.displayName,
    "/v",
    filePath,
  ];
}

export function windowsVerifyArguments(filePath) {
  return ["verify", "/pa", "/all", "/v", filePath];
}

export function innoSignToolDefinition(configuration) {
  return `$q${configuration.signTool}$q sign /sha1 ${configuration.certificateSha1} /fd SHA256 /tr $q${configuration.timestampUrl}$q /td SHA256 /d $q${packageManifest.metadata.displayName}$q /v $f`;
}

export function innoSignToolCompilerArgument(compilerMajor, configuration) {
  const definition = `metawork=${innoSignToolDefinition(configuration)}`;
  return compilerMajor === 7 ? `--signtool=${definition}` : `/S${definition}`;
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

async function signWindowsFile(configuration, filePath, label) {
  await runChild(
    configuration.signTool,
    windowsSignArguments(configuration, filePath),
    { cwd: repositoryRoot, label, timeoutMs: null },
  );
  await verifyWindowsSignature(
    configuration,
    filePath,
    `${label} verification`,
  );
}

async function verifyWindowsSignature(configuration, filePath, label) {
  await runChild(configuration.signTool, windowsVerifyArguments(filePath), {
    cwd: repositoryRoot,
    label,
    timeoutMs: null,
  });
}

async function packageWindows() {
  if (process.platform !== "win32") {
    throw new Error("package:windows must run on Windows");
  }
  const options = parseWindowsPackageArguments(process.argv.slice(2));
  const signing = windowsSigningConfiguration(options);
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
  if (signing) {
    await signWindowsFile(
      signing,
      path.join(
        windowsRuntimeStagePath,
        "bin",
        `${packageManifest.identity.executableName}.exe`,
      ),
      "MetaWork executable signing",
    );
    await verifyWindowsSignature(
      signing,
      path.join(windowsRuntimeStagePath, "bin", "WebView2Loader.dll"),
      "Microsoft WebView2Loader signature verification",
    );
  }

  const installerStem = windowsInstallerArtifactName.slice(0, -".exe".length);
  const definitions = [
    `AppVersion=${packageManifest.metadata.version}`,
    `AppDisplayName=${packageManifest.metadata.displayName}`,
    `AppExecutableName=${packageManifest.identity.executableName}`,
    `AppFileVersion=${windowsFileVersion(packageManifest.metadata.version)}`,
  ];
  if (signing) definitions.push("AppSignTool=metawork");
  const signingCompilerArgument = signing
    ? [innoSignToolCompilerArgument(compilerMajor, signing)]
    : [];
  const compilerArguments =
    compilerMajor === 7
      ? [
          "--quiet-progress",
          `--output-dir=${path.dirname(windowsInstallerArtifactPath)}`,
          `--output-filename=${installerStem}`,
          ...signingCompilerArgument,
          ...definitions.map((definition) => `--define=${definition}`),
        ]
      : [
          "/Qp",
          `/O${path.dirname(windowsInstallerArtifactPath)}`,
          `/F${installerStem}`,
          ...signingCompilerArgument,
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
  if (signing) {
    await verifyWindowsSignature(
      signing,
      windowsInstallerArtifactPath,
      "Windows installer signature verification",
    );
  }
  const digest = verifyWindowsInstaller(windowsInstallerArtifactPath);
  console.log(
    `built ${signing ? "signed" : "unsigned"} Windows installer with Inno Setup ${compilerMajor}: ${windowsInstallerArtifactPath} (sha256=${digest})`,
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
