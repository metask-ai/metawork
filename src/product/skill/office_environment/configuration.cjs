// Select the actual private interpreter architecture, never a PATH runtime.
const key =
  { win32: "windows", darwin: "macos" }[process.platform] +
  "-" +
  { x64: "x86_64", arm64: "aarch64" }[process.arch];
const source = require("./environment.json");
if (source.schemaVersion !== 2 || !source.targets[key])
  throw Error("Unsupported private Office Node target");
module.exports = source.targets[key];
