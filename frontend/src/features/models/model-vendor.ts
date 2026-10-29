import type { BuiltinProviderId } from "../../bridge/contracts.ts";

export type ModelVendor = BuiltinProviderId | "custom";

/** Presentation only, for the official catalog; never infer a custom source's vendor. */
export function catalogModelVendor(modelId: string): ModelVendor {
  const family = modelId.toLowerCase().split("-", 1)[0];
  switch (family) {
    case "deepseek":
    case "glm":
    case "kimi":
    case "minimax":
      return family;
    default:
      return "custom";
  }
}
