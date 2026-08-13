type ClassName = string | false | null | undefined | ((state: any) => string | undefined);

export function cn(...inputs: ClassName[]): any {
  if (inputs.some((input) => typeof input === "function")) {
    return (state: any) =>
      inputs
        .map((input) => (typeof input === "function" ? input(state) : input))
        .filter(Boolean)
        .join(" ");
  }
  return inputs.filter(Boolean).join(" ");
}

export const focusRing =
  "outline-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-(--ui-focus-ring)";

export const controlBase =
  "border border-(--ui-border) bg-(--ui-surface-panel) text-(--ui-content-primary) placeholder:text-(--ui-content-muted) transition-colors disabled:cursor-not-allowed disabled:opacity-50";
