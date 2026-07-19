export const nativeAutomationTokens = Object.freeze([
  "metawork:agent-events",
  "metawork.events.ack",
  "metawork.events.fetch",
  "metawork.gate5.emitFixture",
  "metawork.gate5.worker_wake",
  '"fixture":"inline"',
  '"fixture":"object"',
]);

export function findNativeAutomationToken(bytes) {
  for (const token of nativeAutomationTokens) {
    if (bytes.includes(Buffer.from(token))) return token;
  }
  return null;
}

export function assertNativeAutomationIsolation(bytes, artifact) {
  const token = findNativeAutomationToken(bytes);
  if (token !== null)
    throw new Error(
      `release Native artifact contains MetaWork automation token ${token}: ${artifact}`,
    );
}
