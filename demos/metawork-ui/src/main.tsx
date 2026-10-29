import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./app/App.tsx";
import { installWindowChromeBridge } from "./bridge/window-chrome.ts";
import { I18nProvider } from "./i18n/provider.tsx";
import { DemoSkillPicker } from "./demo/SkillPicker.tsx";
import { DemoWorkspacePicker } from "./demo/WorkspacePicker.tsx";
import "./index.css";
import "./demo/visual.css";

installWindowChromeBridge();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <I18nProvider>
      <App />
      <DemoWorkspacePicker />
      <DemoSkillPicker />
    </I18nProvider>
  </StrictMode>,
);
