import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

const normalize = (name) => name.toLowerCase().replace(/[_.-]+/gu, "-");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function officeComponentSources(root) {
  const sources = JSON.parse(
    readFileSync(
      path.join(root, "build_support/office-runtime.windows-x64.sources.json"),
      "utf8",
    ),
  );
  const wheels = JSON.parse(
    readFileSync(
      path.join(root, "build_support/office-python.windows-x64.lock.json"),
      "utf8",
    ),
  );
  const requirements = readFileSync(
    path.join(root, "scripts/office-requirements.txt"),
  );
  if (
    sources.schema !== 1 ||
    sources.target !== "x86_64-windows-msvc" ||
    wheels.schema !== 1 ||
    wheels.target !== sources.target ||
    wheels.python !== "3.13" ||
    wheels.requirementsSha256 !== digest(requirements)
  )
    throw new Error(
      "Office producer source locks do not match the current target and requirements",
    );
  const expected = new Map(
    requirements
      .toString("utf8")
      .split(/\r?\n/u)
      .filter(Boolean)
      .map((line) => {
        const match = /^([\w-]+)==([^\s]+)$/u.exec(line);
        if (!match)
          throw new Error("Office producer requirements must be fully pinned");
        return [normalize(match[1]), match[2]];
      }),
  );
  const selected = new Set();
  for (const wheel of wheels.wheels) {
    const name = normalize(wheel.name);
    if (
      selected.has(name) ||
      expected.get(name) !== wheel.version ||
      !new URL(wheel.url).pathname.endsWith(".whl")
    )
      throw new Error(
        "Office wheel lock has a missing, duplicate or different requirement",
      );
    selected.add(name);
  }
  if (selected.size !== expected.size)
    throw new Error(
      "Office wheel lock does not cover every pinned requirement",
    );
  for (const item of [
    ...Object.values(sources).filter((value) => typeof value === "object"),
    ...wheels.wheels,
  ]) {
    if (
      !/^[a-f0-9]{64}$/u.test(item.sha256) ||
      new URL(item.url).protocol !== "https:" ||
      (item.bytes !== undefined &&
        (!Number.isSafeInteger(item.bytes) ||
          item.bytes <= 0 ||
          item.bytes > 512 * 1024 * 1024))
    )
      throw new Error(
        "Office dependency needs a fixed HTTPS source, digest and bounded size",
      );
  }
  return { sources, wheels };
}
