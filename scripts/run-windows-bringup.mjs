import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "win32") {
  throw new Error("test:windows:bringup requires Windows");
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const environment = { ...process.env };

for (const script of [
  "test",
  "test:lifecycle",
  "build:debug",
  "probe:agentcore:staged",
  "test:agentcore-vertical:windows",
  "build:release",
]) {
  await runNpm(script);
}

console.log(
  "Windows integration baseline passed: staged revision 3 bundle, SDK candidate probe, lifecycle, Native Debug/Release, and AgentCore vertical automation.",
);

function runNpm(script) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe",
      ["/d", "/s", "/c", `npm run ${script}`],
      { cwd: root, env: environment, stdio: "inherit" },
    );
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0 && signal === null) resolve();
      else {
        reject(
          new Error(`npm run ${script} failed: code=${code} signal=${signal}`),
        );
      }
    });
  });
}
