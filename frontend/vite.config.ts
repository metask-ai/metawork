import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import rootPackage from "../package.json" with { type: "json" };
import { readNativePackageManifest } from "../scripts/package-metadata.mjs";
import { cspPlaceholder, developmentCsp, releaseCsp } from "./csp.mjs";

const repositoryRoot = fileURLToPath(new URL("../", import.meta.url));
const productMetadata = readNativePackageManifest(repositoryRoot).metadata;

export default defineConfig(({ command }) => ({
  define: {
    __METAWORK_PRODUCT_VERSION__: JSON.stringify(productMetadata.version),
    __NATIVE_SDK_VERSION__: JSON.stringify(
      rootPackage.devDependencies["@native-sdk/cli"],
    ),
  },
  plugins: [
    react(),
    tailwindcss(),
    {
      name: "metawork-csp",
      transformIndexHtml(html) {
        if (!html.includes(cspPlaceholder)) {
          throw new Error(`missing CSP placeholder: ${cspPlaceholder}`);
        }
        return html.replace(
          cspPlaceholder,
          command === "serve" ? developmentCsp : releaseCsp,
        );
      },
    },
  ],
  build: {
    target: "safari16",
    cssTarget: "safari16",
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
  },
}));
