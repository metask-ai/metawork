export function webViewBridgeExpression(command, payload) {
  return `(async () => {
    try {
      return {
        ok: true,
        result: await window.zero.invoke(${JSON.stringify(command)}, ${JSON.stringify(payload)}),
      };
    } catch (error) {
      return {
        ok: false,
        error: {
          code: typeof error?.code === "string" ? error.code : null,
          message: String(error?.message ?? error),
          name: typeof error?.name === "string" ? error.name : null,
        },
      };
    }
  })()`;
}

export async function invokeWebViewBridge(webview, command, payload) {
  const response = await webview.evaluate(
    webViewBridgeExpression(command, payload),
  );
  if (
    response === null ||
    typeof response !== "object" ||
    typeof response.ok !== "boolean"
  )
    throw new Error(
      `${command} returned an invalid Renderer response: ${JSON.stringify(response)}`,
    );
  if (!response.ok) {
    const error = new Error(
      `${command} failed: ${JSON.stringify(response.error)}`,
    );
    error.bridgeCommand = command;
    error.bridgeResponseError = response.error;
    throw error;
  }
  return response.result;
}
