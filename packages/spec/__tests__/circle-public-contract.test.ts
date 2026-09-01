import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const REPO_ROOT = join(import.meta.dir, "../../..");
const discoveryLexiconRoot = join(
  REPO_ROOT,
  "packages/lexicons/app/thesocialwire/discovery",
);
const defs = JSON.parse(
  readFileSync(join(discoveryLexiconRoot, "defs.json"), "utf8"),
) as { defs: Record<string, any> };
const openAPI = Bun.YAML.parse(
  readFileSync(join(REPO_ROOT, "packages/spec/openapi.yaml"), "utf8"),
) as {
  security: Array<Record<string, unknown>>;
  components: { schemas: Record<string, any> };
  paths: Record<string, Record<string, any>>;
};
const manifest = JSON.parse(
  readFileSync(join(REPO_ROOT, "packages/spec/endpoint-manifest.json"), "utf8"),
) as {
  entries: Array<{ method: string; path: string; xrpcNsid?: string }>;
};

const circleMethods = [
  ["getCircleCatalog", "GET"],
  ["getCircleEdition", "GET"],
  ["setCircleItemHidden", "POST"],
] as const;

describe("Your Circle public XRPC contract", () => {
  it("uses authenticated queries for reads and an authenticated procedure for hide state", () => {
    expect(openAPI.security).toEqual([{ ATProtoOAuthDPoP: [] }]);

    for (const [method, verb] of circleMethods) {
      const nsid = `app.thesocialwire.discovery.${method}`;
      const lexicon = JSON.parse(
        readFileSync(join(discoveryLexiconRoot, `${method}.json`), "utf8"),
      );
      const operation = openAPI.paths[`/xrpc/${nsid}`][verb.toLowerCase()];
      const manifestEntry = manifest.entries.find(
        (entry) => entry.path === `/xrpc/${nsid}`,
      );

      expect(lexicon.id).toBe(nsid);
      expect(lexicon.defs.main.type).toBe(
        verb === "GET" ? "query" : "procedure",
      );
      expect(operation.security).toBeUndefined();
      expect(operation.responses["401"]).toBeDefined();
      expect(manifestEntry?.method).toBe(verb);
      expect(manifestEntry?.xrpcNsid).toBe(nsid);
    }
  });

  it("publishes bounded sharer identity and circle relationship details", () => {
    const sharer = defs.defs.circleSharer;
    const identity = defs.defs.circlePublicIdentity;
    const story = defs.defs.circleStory;
    const openAPISharer = openAPI.components.schemas.CircleSharer;
    const openAPIStory = openAPI.components.schemas.CircleStory;

    expect(identity.required).toEqual(["did", "handle"]);
    expect(Object.keys(identity.properties)).toEqual([
      "did",
      "handle",
      "displayName",
      "avatarUrl",
    ]);
    expect(sharer.properties.relationship.knownValues).toEqual([
      "direct",
      "one_hop",
    ]);
    expect(sharer.properties.action.knownValues).toEqual([
      "recommended",
      "shared",
      "discussed",
    ]);
    expect(sharer.required).toContain("sourceUri");
    expect(sharer.required).toContain("timestamp");
    expect(story.required).toContain("sharerCount");
    expect(story.properties.sharerCount.minimum).toBe(0);
    expect(story.properties.sharers.maxLength).toBe(5);
    expect(story.properties.discussionCount.minimum).toBe(0);

    expect(openAPISharer.properties.relationship.enum).toEqual([
      "direct",
      "one_hop",
    ]);
    expect(openAPISharer.properties.action.enum).toEqual([
      "recommended",
      "shared",
      "discussed",
    ]);
    expect(openAPIStory.required).toContain("sharerCount");
    expect(openAPIStory.properties.sharerCount.minimum).toBe(0);
    expect(openAPIStory.properties.sharers.maxItems).toBe(5);
    expect(openAPIStory.properties.discussionCount.minimum).toBe(0);
  });

  it("exposes editorial story modules without a people rail or private ranking provenance", () => {
    const lexiconEdition = defs.defs.circleEdition;
    const openAPIEdition = openAPI.components.schemas.CircleEdition;
    const exposedContract = JSON.stringify({
      lexicon: {
        identity: defs.defs.circlePublicIdentity,
        sharer: defs.defs.circleSharer,
        story: defs.defs.circleStory,
        edition: lexiconEdition,
      },
      openAPI: {
        identity: openAPI.components.schemas.CirclePublicIdentity,
        sharer: openAPI.components.schemas.CircleSharer,
        story: openAPI.components.schemas.CircleStory,
        edition: openAPIEdition,
      },
    });

    for (const property of [
      "actorKeyHash",
      "actor_key_hash",
      "rankingScore",
      "ranking_score",
      "sourceApp",
      "source_app",
      "sourceCollection",
      "source_collection",
      "sourceAction",
      "source_action",
    ]) {
      expect(exposedContract).not.toContain(property);
    }

    expect(lexiconEdition.required).toEqual(
      expect.arrayContaining([
        "stories",
        "topStoryIds",
        "publicationSpotlights",
        "storyRails",
        "trendingStoryIds",
      ]),
    );
    expect(lexiconEdition.properties.people).toBeUndefined();
    expect(openAPIEdition.properties.people).toBeUndefined();
    expect(openAPIEdition.additionalProperties).toBe(false);
  });

  it("uses storyId for the hide mutation input and response", () => {
    const hide = JSON.parse(
      readFileSync(join(discoveryLexiconRoot, "setCircleItemHidden.json"), "utf8"),
    );
    const operation = openAPI.paths[
      "/xrpc/app.thesocialwire.discovery.setCircleItemHidden"
    ].post;
    const requestSchema =
      operation.requestBody.content["application/json"].schema;
    const responseSchema =
      operation.responses["200"].content["application/json"].schema;

    expect(hide.defs.main.input.schema.required).toEqual(["storyId", "hidden"]);
    expect(hide.defs.main.output.schema.required).toEqual(["storyId", "hidden"]);
    expect(requestSchema.required).toEqual(["storyId", "hidden"]);
    expect(responseSchema.required).toEqual(["storyId", "hidden"]);
  });

  it("ships authenticated AppView and Gateway Bruno requests for every method", () => {
    for (const service of ["appview", "gateway"]) {
      for (const [method, verb] of circleMethods) {
        const nsid = `app.thesocialwire.discovery.${method}`;
        const file = join(
          REPO_ROOT,
          `services/${service}/bruno/XRPC/${nsid}.bru`,
        );
        expect(existsSync(file), file).toBe(true);
        const request = readFileSync(file, "utf8");
        expect(request).toContain(
          `${verb.toLowerCase()} {\n  url: {{baseUrl}}/xrpc/${nsid}`,
        );
        expect(request).toContain("Authorization: Bearer {{oauthAccessToken}}");
        expect(request).toContain("DPoP: {{dpopProof}}");
      }
    }
  });
});
