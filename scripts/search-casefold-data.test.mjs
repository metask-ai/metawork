import test from "node:test";
import { generateSearchCasefold } from "./generate-search-casefold.mjs";

test("search Unicode mappings match the pinned official data and generated source", async () => {
  await generateSearchCasefold({ check: true });
});
