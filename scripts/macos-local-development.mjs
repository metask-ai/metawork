import { runDevelopment } from "./package-macos.mjs";

try {
  runDevelopment();
} catch (error) {
  console.error(`error: ${error instanceof Error ? error.message : error}`);
  process.exitCode = 1;
}
