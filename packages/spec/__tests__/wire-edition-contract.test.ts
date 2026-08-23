import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const openAPI = Bun.YAML.parse(
  readFileSync(join(import.meta.dir, "../openapi.yaml"), "utf8"),
) as {
  components: { schemas: { WireEdition: { properties: { topStoryIds: { maxItems: number } } } } };
  paths: Record<string, { get: { parameters: Array<{ name: string; schema: { enum?: string[] } }> } }>;
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

const editionQueryLexicon = JSON.parse(
  readFileSync(
    join(
      import.meta.dir,
      "../../lexicons/app/thesocialwire/discovery/getWireEdition.json",
    ),
    "utf8",
  ),
) as {
  defs: { main: { parameters: { properties: { region: { knownValues: string[] } } } } };
};

describe("The Wire edition contract", () => {
  it("allows one feature and three supporting Top Stories", () => {
    expect(openAPI.components.schemas.WireEdition.properties.topStoryIds.maxItems).toBe(4);
    expect(lexicon.defs.wireEdition.properties.topStoryIds.maxLength).toBe(4);
  });

  it("exposes only the coarse outside-US relevance hint", () => {
    const parameters = openAPI.paths[
      "/xrpc/app.thesocialwire.discovery.getWireEdition"
    ].get.parameters;
    expect(parameters.find(({ name }) => name === "region")?.schema.enum).toEqual([
      "outside-us",
    ]);
    expect(
      editionQueryLexicon.defs.main.parameters.properties.region.knownValues,
    ).toEqual(["outside-us"]);
  });
});
