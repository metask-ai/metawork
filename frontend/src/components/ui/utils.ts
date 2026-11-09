import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

type ClassName = ClassValue | ((state: any) => ClassValue);

export function cn(...inputs: ClassValue[]): string;
export function cn(...inputs: ClassName[]): string | ((state: any) => string);
export function cn(...inputs: ClassName[]): string | ((state: any) => string) {
  if (inputs.some((input) => typeof input === "function")) {
    return (state: any) =>
      twMerge(
        clsx(
          inputs.map((input) =>
            typeof input === "function" ? input(state) : input,
          ),
        ),
      );
  }
  return twMerge(clsx(inputs));
}

export const focusRing =
  "outline-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-(--ui-focus-ring)";

export const controlFocus = "ui-control-focus outline-none";

export const controlBase =
  "border border-(--ui-border) bg-(--ui-surface-panel) text-(--ui-content-primary) placeholder:text-(--ui-content-muted) transition-colors disabled:cursor-not-allowed disabled:opacity-50";
