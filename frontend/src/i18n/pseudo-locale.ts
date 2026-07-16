const accented: Record<string, string> = {
  a: "á",
  e: "ë",
  i: "ï",
  o: "ö",
  u: "ü",
  A: "Á",
  E: "Ë",
  I: "Ï",
  O: "Ö",
  U: "Ü",
};

export function pseudoLocalize(message: string): string {
  const parts = message.split(/(\{[a-zA-Z0-9_]+\})/g);
  const transformed = parts
    .map((part) =>
      part.startsWith("{")
        ? part
        : [...part]
            .map((character) => accented[character] ?? character)
            .join(""),
    )
    .join("");
  const padding = "~".repeat(Math.max(3, Math.ceil(message.length * 0.3)));
  return `［${transformed} ${padding}］`;
}
