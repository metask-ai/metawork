import deepseekUrl from "@lobehub/icons-static-svg/icons/deepseek.svg?url";
import kimiUrl from "@lobehub/icons-static-svg/icons/kimi.svg?url";
import minimaxUrl from "@lobehub/icons-static-svg/icons/minimax.svg?url";
import glmUrl from "@lobehub/icons-static-svg/icons/zai.svg?url";
import { Icon } from "../../components/ui/Icon.tsx";
import type { ModelVendor } from "./model-vendor.ts";

const marks: Record<Exclude<ModelVendor, "custom">, string> = {
  deepseek: deepseekUrl,
  kimi: kimiUrl,
  minimax: minimaxUrl,
  glm: glmUrl,
};

export function ModelVendorIcon({
  vendor = "custom",
}: {
  vendor?: ModelVendor;
}) {
  return (
    <span
      className="model-vendor-icon"
      data-vendor={vendor}
      aria-hidden="true"
      style={
        vendor === "custom"
          ? undefined
          : { maskImage: `url("${marks[vendor]}")` }
      }
    >
      {vendor === "custom" && <Icon name="box" />}
    </span>
  );
}
