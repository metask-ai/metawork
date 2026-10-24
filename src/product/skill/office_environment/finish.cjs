// Fixed Office libraries only. npm performs dependency installation.
const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
const { spawnSync } = require("node:child_process");

const config = require("./configuration.cjs");
function validDirectory(root) {
  const stat = fs.lstatSync(root);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    throw Error("Office final path must be a real directory");
}
function check(root) {
  validDirectory(root);
  if (
    config.target !== "windows-x86_64" &&
    fs.realpathSync(process.execPath) !==
      fs.realpathSync(path.join(root, config.layout.nodeExecutable))
  )
    throw Error("Office Node is not running from its selected environment");
  if (process.version !== "v" + require("./configuration.cjs").node.version)
    throw new Error("Unexpected private Node version");
  const load = createRequire(path.join(root, "package.json"));
  for (const [name, version] of Object.entries(
    require("./package.json").dependencies,
  ))
    if (
      JSON.parse(
        fs.readFileSync(path.join(root, "node_modules", name, "package.json")),
      ).version !== version
    )
      throw new Error("Private library version mismatch");
  if (!load("docx").Document || !load("pptxgenjs"))
    throw new Error("Private Node libraries unavailable");
}

function install(stage, resources) {
  for (const name of ["package.json", "package-lock.json"])
    fs.copyFileSync(
      path.join(resources, name),
      path.join(stage, name),
      fs.constants.COPYFILE_EXCL,
    );
  const npm = path.join(stage, config.layout.npmCli);
  const result = spawnSync(
    process.execPath,
    [
      npm,
      "ci",
      "--prefix",
      stage,
      "--global=false",
      "--cache",
      path.join(stage, ".npm-cache"),
      "--omit=dev",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
    ],
    {
      cwd: stage,
      stdio: "inherit",
      timeout: 600000,
      windowsHide: true,
      env: { ...process.env, NODE_OPTIONS: "", NODE_PATH: "" },
    },
  );
  if (result.error || result.status !== 0)
    throw new Error("Private npm preparation failed");
  fs.rmSync(path.join(stage, ".npm-cache"), { recursive: true, force: true });
  check(stage);
}
async function main() {
  if (process.argv[2] === "--check") {
    check(process.argv[3]);
    console.log(process.argv[3]);
    return;
  }
  if (process.argv[2] === "--install" && process.platform === "darwin") {
    install(process.argv[3], process.argv[4]);
    return;
  }
  if (process.platform !== "win32" || process.argv.length !== 5)
    throw Error("Invalid fixed Office preparation invocation");
  const [stage, final, resources] = process.argv.slice(2);
  install(stage, resources);
  for (let attempt = 0; ; attempt++) {
    try {
      fs.renameSync(stage, final);
      break;
    } catch (failure) {
      if (fs.existsSync(final)) {
        if (config.target === "windows-x86_64") check(final);
        else checkFinal(final);
        // The cmd parent cleans staging after this staged node.exe exits.
        break;
      }
      if (!["EPERM", "EACCES", "EBUSY"].includes(failure.code) || attempt === 4)
        throw failure;
      await new Promise((resolve) => setTimeout(resolve, 100 * (attempt + 1)));
    }
  }
  if (config.target === "windows-aarch64") checkFinal(final);
  console.log(final);
}
function checkFinal(final) {
  validDirectory(final);
  const checked = spawnSync(
    path.join(final, config.layout.nodeExecutable),
    [__filename, "--check", final],
    { stdio: "inherit", timeout: 60000, windowsHide: true },
  );
  if (checked.error || checked.status !== 0)
    throw Error("Published Office Node is unusable");
}
module.exports = { check };
if (require.main === module)
  main().catch((failure) => {
    console.error(
      "Private Node preparation failed; completed environments were preserved.",
    );
    console.error(failure.code ?? "dependency_verification_failed");
    process.exitCode = 1;
  });
