import assert from "node:assert/strict";

// Desktop probes use a dedicated, isolated Custom Provider. Choosing its
// first configured fixture model is an explicit probe action, with no write
// to the product's starting preference or provider-local selection.
export function fixtureModelSelection(snapshot, target) {
  if (!target) {
    assert.equal(snapshot.models.customProviders.length, 1);
    const fixture = snapshot.models.customProviders[0];
    assert.ok(fixture.models.length > 0);
    target = { sourceId: fixture.id, modelId: fixture.models[0].id };
  }
  const source = [
    ...snapshot.models.providers,
    ...snapshot.models.customProviders,
  ].find((item) => item.id === target.sourceId);
  assert.ok(source, "fixture model source is missing");
  assert.ok(
    source.models.some(
      (item) => item.id === target.modelId && item.ready !== false,
    ),
  );
  assert.match(source.sourceGeneration, /^[1-9][0-9]*$/);
  assert.match(source.catalogGeneration, /^[1-9][0-9]*$/);
  return {
    targetModelRef: target,
    expectedSourceGeneration: source.sourceGeneration,
    expectedCatalogGeneration: source.catalogGeneration,
  };
}
