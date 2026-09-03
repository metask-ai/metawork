export const nativeAutomationTokens = Object.freeze([
  "metawork.product_delivery.emit",
  "METAWORK_AGENTCORE_VERTICAL_PROVIDER_BASE_URL",
  "METAWORK_AUTOMATION_ATTACHMENTS",
  "METAWORK_MODEL_CONNECTION_READINESS",
  "metawork-agentcore-vertical-fixture-key",
  "metawork-agentcore-vertical-fixture-model",
  "automation-account",
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
