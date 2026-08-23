import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";

import {
  getWireEdition,
  isWireNewsEditionEnabled,
  type WireEditionPage,
} from "@/lib/wireEditionClient";

const originalFetch = globalThis.fetch;
const originalEnvironment = { ...process.env };

const edition: WireEditionPage = {
  editionVersion: "1",
  generationId: "generation-1",
  generatedAt: "2026-08-21T12:00:00.000Z",
  language: "en",
  source: "ranked",
  degraded: false,
  stories: [
    {
      itemId: "story-1",
      canonicalUrl: "https://news.example/story",
      title: "A Story",
      source: {
        name: "Example News",
        domain: "news.example",
        publication: "Example News",
        publicationKey: "at://did:plc:news/site.standard.publication/main",
        homepageUrl: "https://news.example",
        iconUrl: "https://news.example/icon.png",
      },
      reasons: ["breaking_story"],
      provenance: ["standard_site"],
    },
  ],
  topStoryIds: ["story-1"],
  publicationSpotlights: [],
  storyRails: [],
  people: [],
  trendingStoryIds: ["story-1"],
  moreCursor: "next-page",
};

describe("The Wire edition client", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.example.test";
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    process.env = { ...originalEnvironment };
  });

  it("keeps the hosted news edition behind its rollout gate", () => {
    delete process.env.NEXT_PUBLIC_WIRE_NEWS_EDITION_ENABLED;
    process.env.NEXT_PUBLIC_APP_ENV = "test";
    expect(isWireNewsEditionEnabled()).toBe(false);
    process.env.NEXT_PUBLIC_WIRE_NEWS_EDITION_ENABLED = "true";
    expect(isWireNewsEditionEnabled()).toBe(true);
  });

  it("loads a language-scoped atomic edition without credentials", async () => {
    const requests: Array<{ input: string | URL | Request; init?: RequestInit }> = [];
    const fetchMock = mock(
      async (input: string | URL | Request, init?: RequestInit) => {
        requests.push({ input, init });
        return Response.json(edition);
      },
    );
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const result = await getWireEdition({
      language: "en",
      region: "outside-us",
    });

    expect(result.generationId).toBe("generation-1");
    expect(result.stories[0]?.source.iconUrl).toBe(
      "https://news.example/icon.png",
    );
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(String(requests[0]?.input)).toBe(
      "https://api.example.test/xrpc/app.thesocialwire.discovery.getWireEdition?lang=en&region=outside-us",
    );
    expect(requests[0]?.init?.credentials).toBe("omit");
  });
});
