import { refractor } from "refractor/core";
import bash from "refractor/bash";
import c from "refractor/c";
import cmake from "refractor/cmake";
import cpp from "refractor/cpp";
import csharp from "refractor/csharp";
import css from "refractor/css";
import diff from "refractor/diff";
import docker from "refractor/docker";
import go from "refractor/go";
import ini from "refractor/ini";
import java from "refractor/java";
import javascript from "refractor/javascript";
import json from "refractor/json";
import jsx from "refractor/jsx";
import makefile from "refractor/makefile";
import markdown from "refractor/markdown";
import markup from "refractor/markup";
import powershell from "refractor/powershell";
import python from "refractor/python";
import ruby from "refractor/ruby";
import rust from "refractor/rust";
import sql from "refractor/sql";
import toml from "refractor/toml";
import tsx from "refractor/tsx";
import typescript from "refractor/typescript";
import yaml from "refractor/yaml";
import zig from "refractor/zig";

for (const grammar of [
  bash,
  c,
  cmake,
  cpp,
  csharp,
  css,
  diff,
  docker,
  go,
  ini,
  java,
  javascript,
  json,
  jsx,
  makefile,
  markdown,
  markup,
  powershell,
  python,
  ruby,
  rust,
  sql,
  toml,
  tsx,
  typescript,
  yaml,
  zig,
]) {
  refractor.register(grammar);
}

export function highlightSource(content: string, language: string): unknown {
  return refractor.highlight(content, language);
}
