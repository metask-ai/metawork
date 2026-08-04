import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { BridgeClient } from "../bridge/client.ts";
import type { WindowChromeState } from "../bridge/decode-contracts.ts";
import type { WindowControlAction } from "../components/ui/WindowControls.tsx";
import { desktopPlatform } from "../platform/keyboard.ts";
import type { WindowTitlebarClickCount } from "../platform/window-chrome.ts";

const initialState: WindowChromeState = { maximized: false };

export function useWindowChrome(client: BridgeClient) {
  const platform = useMemo(desktopPlatform, []);
  const [state, setState] = useState<WindowChromeState>(initialState);
  const stateRequest = useRef(0);

  const commitState = useCallback(
    async (pending: Promise<WindowChromeState>) => {
      const request = ++stateRequest.current;
      const next = await pending;
      if (request === stateRequest.current) setState(next);
      return next;
    },
    [],
  );

  useEffect(() => {
    if (platform !== "windows" || !client.available()) return;
    let frame: number | null = null;

    const refresh = async () => {
      try {
        await commitState(client.windowState());
      } catch {
        // Bootstrap chrome stays usable when product delivery is unavailable.
      }
    };
    const scheduleRefresh = () => {
      if (frame !== null) return;
      frame = window.requestAnimationFrame(() => {
        frame = null;
        void refresh();
      });
    };

    void refresh();
    window.addEventListener("resize", scheduleRefresh);
    window.addEventListener("focus", scheduleRefresh);
    return () => {
      stateRequest.current += 1;
      if (frame !== null) window.cancelAnimationFrame(frame);
      window.removeEventListener("resize", scheduleRefresh);
      window.removeEventListener("focus", scheduleRefresh);
    };
  }, [client, commitState, platform]);

  const beginDrag = useCallback(
    (clicks: WindowTitlebarClickCount) => {
      void commitState(client.beginWindowDrag(clicks)).catch(() => undefined);
    },
    [client, commitState],
  );

  const control = useCallback(
    (action: WindowControlAction) => {
      void commitState(client.controlWindow(action)).catch(() => undefined);
    },
    [client, commitState],
  );

  const openSystemMenu = useCallback(() => {
    void commitState(client.openWindowSystemMenu()).catch(() => undefined);
  }, [client, commitState]);

  return {
    maximized: state.maximized,
    beginDrag,
    toggleFromDoubleClick:
      platform === "windows" ? () => beginDrag(2) : undefined,
    control,
    openSystemMenu: platform === "windows" ? openSystemMenu : undefined,
  };
}
