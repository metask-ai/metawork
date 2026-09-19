// Real desktop paint gate for the input-only HWND. CDP touches only the
// isolated test WebView; product code and Renderer contracts stay unchanged.
import { createServer } from "node:net";
import path from "node:path";

export async function allocateWebViewTestPort() {
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const port = server.address().port;
  await new Promise((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
  return port;
}

export async function connectTestWebView(port, { htmlTitle } = {}) {
  let page;
  const deadline = Date.now() + 10_000;
  while (!page && Date.now() < deadline) {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
      signal: AbortSignal.timeout(1000),
    }).catch(() => null);
    if (response?.ok) {
      page = (await response.json()).find(
        (candidate) =>
          candidate.type === "page" &&
          (htmlTitle
            ? candidate.title === htmlTitle &&
              candidate.url.startsWith("data:text/html")
            : new URL(candidate.url).origin ===
              "https://native-sdk-app.localhost"),
      );
    }
    if (!page) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  if (!page) throw new Error("Isolated WebView paint target unavailable");
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map();
  let nextId = 0;
  socket.addEventListener("message", ({ data }) => {
    const response = JSON.parse(data);
    pending.get(response.id)?.(response);
  });
  async function send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Paint probe ${method} timed out`));
      }, 5000);
      pending.set(id, (response) => {
        clearTimeout(timer);
        pending.delete(id);
        if (response.error) reject(new Error(JSON.stringify(response.error)));
        else resolve(response.result);
      });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("Paint debugger connection timed out")),
        5000,
      );
      socket.addEventListener(
        "open",
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true },
      );
      socket.addEventListener(
        "error",
        () => {
          clearTimeout(timer);
          reject(new Error("Paint debugger connection failed"));
        },
        { once: true },
      );
    });
    return {
      send,
      async evaluate(expression) {
        const result = await send("Runtime.evaluate", {
          expression,
          awaitPromise: true,
          returnByValue: true,
        });
        if (result.exceptionDetails)
          throw new Error(JSON.stringify(result.exceptionDetails));
        return result.result.value;
      },
      close() {
        socket.close();
      },
    };
  } catch (error) {
    socket.close();
    throw error;
  }
}

export async function probeTopResizePaint({
  port,
  runProbe,
  evidenceDir,
  fixedDrag = false,
}) {
  const webview = await connectTestWebView(
    port,
    fixedDrag ? { htmlTitle: "Fixed native drag input probe" } : {},
  );
  const { send } = webview;
  try {
    for (const [index, color] of [
      "#cc3366",
      "#2277aa",
      "#33aa66",
      "#101010",
      "#ffffff",
    ].entries()) {
      await send("Emulation.setEmulatedMedia", {
        features: [
          { name: "prefers-color-scheme", value: index % 2 ? "dark" : "light" },
        ],
      });
      const result = await send("Runtime.evaluate", {
        expression: `(async () => {
          let strip = document.getElementById('metawork-resize-paint-probe');
          if (!strip) {
            strip = document.createElement('div');
            strip.id = 'metawork-resize-paint-probe';
            strip.style.cssText = 'position:fixed;inset:0 0 auto;height:${fixedDrag ? 40 : 24}px;z-index:2147483647;pointer-events:none';
            document.body.append(strip);
          }
          for (let frame = 0; frame < 12; frame++) {
            strip.style.background = frame % 2 ? ${JSON.stringify(color)} : '#f0c020';
            await new Promise(requestAnimationFrame);
          }
        })()`,
        awaitPromise: true,
      });
      if (result.exceptionDetails)
        throw new Error(JSON.stringify(result.exceptionDetails));
      // Observe the new pixels before any resize, activation, or occlusion can
      // repair stale content underneath the input child.
      const stationaryArgs = ["-ColorHex", color];
      if (fixedDrag) stationaryArgs.push("-FixedDragPaint");
      if (evidenceDir)
        stationaryArgs.push(
          "-OutputPath",
          path.join(evidenceDir, `top-stationary-${index}.png`),
        );
      await runProbe("paint-stationary", stationaryArgs);
      const args = [
        "-ColorHex",
        color,
        "-ProbeWidth",
        String(900 + index * 30),
      ];
      if (fixedDrag) args.push("-FixedDragPaint");
      if (evidenceDir)
        args.push(
          "-OutputPath",
          path.join(evidenceDir, `top-paint-${index}.png`),
        );
      await runProbe("paint", args);
    }
    await send("Runtime.evaluate", {
      expression:
        "document.getElementById('metawork-resize-paint-probe').remove()",
    });
    await send("Emulation.setEmulatedMedia", { features: [] });
  } finally {
    webview.close();
  }
}
