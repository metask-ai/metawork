import deepseekUrl from "@lobehub/icons-static-svg/icons/deepseek.svg?url";
import kimiUrl from "@lobehub/icons-static-svg/icons/kimi.svg?url";
import minimaxUrl from "@lobehub/icons-static-svg/icons/minimax.svg?url";
import glmUrl from "@lobehub/icons-static-svg/icons/zai.svg?url";
import { Icon } from "./Icon.tsx";

const marks = {
  deepseek: deepseekUrl,
  kimi: kimiUrl,
  minimax: minimaxUrl,
  glm: glmUrl,
};

export type Brand = keyof typeof marks | "custom";

export function BrandIcon({ brand = "custom" }: { brand?: Brand }) {
  return (
    <span
      className="model-vendor-icon"
      data-vendor={brand}
      aria-hidden="true"
      style={
        brand === "custom" ? undefined : { maskImage: `url("${marks[brand]}")` }
      }
    >
      {brand === "custom" && <Icon name="box" />}
    </span>
  );
}
