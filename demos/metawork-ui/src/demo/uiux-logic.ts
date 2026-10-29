// Pure helpers shared by the prototype and meaningful edge-case tests.
export function resolveSkillRoot(paths: readonly string[]): string {
  if (
    paths.some(
      (path) =>
        path.startsWith("/") ||
        path.includes("\\") ||
        path.split("/").some((part) => part === ".." || part === "."),
    )
  )
    throw new Error("SKILL_INVALID_PATH");
  const definitions = paths.filter(
    (path) => path === "SKILL.md" || path.endsWith("/SKILL.md"),
  );
  if (!definitions.length) throw new Error("SKILL_DEFINITION_MISSING");
  if (definitions.length !== 1) throw new Error("SKILL_MULTIPLE_DEFINITIONS");
  return definitions[0]!.slice(0, -"SKILL.md".length);
}
export function validateSkillPackage(name: string) {
  if (!/\.(skill|zip)$/i.test(name))
    throw new Error("SKILL_UNSUPPORTED_FORMAT");
}
export function monthAnchors<T extends { date: string; column: number }>(
  days: readonly T[],
): T[] {
  const seen = new Set<string>(),
    occupied = new Set<number>();
  return days.filter((day) => {
    const month = day.date.slice(0, 7);
    if (seen.has(month) || occupied.has(day.column)) return false;
    seen.add(month);
    occupied.add(day.column);
    return true;
  });
}
export function measuredWindowWidth(
  measured: number,
  fallback: number,
  previous: number,
) {
  return measured > 0 ? measured : fallback > 0 ? fallback : previous;
}
