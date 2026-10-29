import assert from "node:assert/strict";
import test from "node:test";
import { editCustomModel } from "../frontend/src/app/edit-custom-model.ts";
import { inspectModelEndpoint } from "../frontend/src/features/settings/model-connection.ts";
function harness(options = {}) {
  const source = {
    id: "model-source",
    builtinProviderId: null,
    displayName: "example.com",
    protocol: "openai_responses",
    normalizedBaseUrl: "https://example.com/v1/responses",
    providerRevision: "7",
    catalogGeneration: "11",
    sourceGeneration: "13",
    credentialStatus: "ready",
    models: [{ id: "old" }],
  };
  const models = { customProviders: [source] };
  const calls = [];
  const accepted = { accepted: true, errorCode: "none" };
  const increment = () =>
    (source.providerRevision = String(BigInt(source.providerRevision) + 1n));
  const client = {
    async updateCustomProvider(input) {
      calls.push(["address", input]);
      if (options.throwAddress) throw Error("connection lost");
      Object.assign(source, {
        protocol: input.protocol,
        normalizedBaseUrl: input.normalizedBaseUrl,
      });
      increment();
      return accepted;
    },
    async replaceCustomProviderCredential(id, revision, key) {
      calls.push(["api_key", { id, revision, key }]);
      increment();
      if (options.failKey)
        return { accepted: false, errorCode: "credential_write_failed" };
      return accepted;
    },
    async replaceCustomModel(input) {
      calls.push(["model_id", input]);
      source.models = [{ id: input.replacement.id }];
      increment();
      source.catalogGeneration = "12";
      return accepted;
    },
  };
  const input = {
    providerId: source.id,
    expectedProviderRevision: "7",
    expectedCatalogGeneration: "11",
    modelId: "old",
    nextModelId: "new",
    protocol: "anthropic_messages",
    endpoint: "https://other.example/v1/messages",
    apiKey: "test-key",
  };
  const refresh = async () => {
    if (options.failRefresh) throw Error("observation failed");
    return structuredClone(models);
  };
  return { source, models, client, calls, input, refresh };
}
test("editing observes canonical revisions between address, credential and model mutations", async () => {
  const h = harness();
  const result = await editCustomModel(
    h.client,
    structuredClone(h.models),
    h.refresh,
    h.input,
  );
  assert.equal(result.accepted, true);
  assert.deepEqual(result.applied, ["address", "api_key", "model_id"]);
  assert.equal(h.calls[0][1].expectedProviderRevision, "7");
  assert.equal(h.calls[1][1].revision, "8");
  assert.equal(h.calls[2][1].expectedProviderRevision, "9");
  assert.equal(h.calls[2][1].expectedCatalogGeneration, "11");
  assert.equal(result.source.providerRevision, "10");
  assert.equal(result.modelId, "new");
});
test("a rejected credential replacement stops remaining writes and returns the latest partial state", async () => {
  const h = harness({ failKey: true });
  const result = await editCustomModel(
    h.client,
    structuredClone(h.models),
    h.refresh,
    h.input,
  );
  assert.equal(result.accepted, false);
  assert.equal(result.reviewRequired, false);
  assert.deepEqual(result.applied, ["address"]);
  assert.equal(result.source.providerRevision, "9");
  assert.equal(result.modelId, "old");
  assert.deepEqual(
    h.calls.map((c) => c[0]),
    ["address", "api_key"],
  );
});
test("stale or uncertain edits require review and never replay writes", async () => {
  for (const options of [{ throwAddress: true }, { failRefresh: true }, {}]) {
    const h = harness(options);
    if (!Object.keys(options).length) h.input.expectedProviderRevision = "6";
    const result = await editCustomModel(
      h.client,
      structuredClone(h.models),
      h.refresh,
      h.input,
    );
    assert.equal(result.accepted, false);
    assert.equal(result.reviewRequired, true);
    assert.equal(h.calls.length, Object.keys(options).length ? 1 : 0);
  }
});
test("a preset edit can keep its credential and change only its model", async () => {
  const h = harness();
  h.source.builtinProviderId = "deepseek";
  Object.assign(h.input, {
    protocol: h.source.protocol,
    endpoint: h.source.normalizedBaseUrl,
    apiKey: "",
  });
  const result = await editCustomModel(
    h.client,
    structuredClone(h.models),
    h.refresh,
    h.input,
  );
  assert.equal(result.accepted, true);
  assert.deepEqual(
    h.calls.map((c) => c[0]),
    ["model_id"],
  );
});
test("endpoint validation rejects inputs that cannot reach a supported Host request path", () => {
  for (const address of [
    "not a url",
    "https://example.com/v1/responses?",
    "https://example.com/v1/responses#",
    "https://@example.com/v1/responses",
    "https://user:pass@example.com/v1/responses",
    "https://example.com/v1/responses?api_key=x",
    "https://example.com/v1/responses#fragment",
    "https://example.com/v1/responses/",
    "https://example.com/v1",
    "http://remote.example/v1/responses",
    "https://example.com/a b/responses",
  ])
    assert.ok(inspectModelEndpoint(address).issue, address);
  for (const address of [
    "http://localhost:8080/v1/responses",
    "http://127.0.0.1:8080/v1/messages",
    "http://[::1]:8080/chat/completions",
  ])
    assert.equal(inspectModelEndpoint(address).issue, null, address);
  assert.deepEqual(inspectModelEndpoint("https://example.com"), {
    protocol: null,
    root: true,
    issue: null,
  });
});
