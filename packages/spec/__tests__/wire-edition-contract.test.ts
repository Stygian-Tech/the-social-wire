import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const openAPI = Bun.YAML.parse(
  readFileSync(join(import.meta.dir, "../openapi.yaml"), "utf8"),
) as {
  components: { schemas: { WireEdition: { properties: { topStoryIds: { maxItems: number } } } } };
};

const lexicon = JSON.parse(
  readFileSync(
    join(
      import.meta.dir,
      "../../lexicons/app/thesocialwire/discovery/defs.json",
    ),
    "utf8",
  ),
) as {
  defs: { wireEdition: { properties: { topStoryIds: { maxLength: number } } } };
};

describe("The Wire edition contract", () => {
  it("allows one feature and three supporting Top Stories", () => {
    expect(openAPI.components.schemas.WireEdition.properties.topStoryIds.maxItems).toBe(4);
    expect(lexicon.defs.wireEdition.properties.topStoryIds.maxLength).toBe(4);
  });
});
