import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import rootPackage from "../package.json" with { type: "json" };
import { cspPlaceholder, developmentCsp, releaseCsp } from "./csp.mjs";

export default defineConfig(({ command }) => ({
  define: {
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
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
  },
}));
