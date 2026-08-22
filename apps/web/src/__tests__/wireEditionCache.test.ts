import { describe, expect, it } from "bun:test";
import { QueryClient, type InfiniteData } from "@tanstack/react-query";

import {
  replaceWireEditionQueryGeneration,
  WIRE_EDITION_QUERY_KEY,
} from "@/hooks/useWireEdition";
import type { WireEditionPage } from "@/lib/wireEditionClient";

function edition(generationId: string, title: string): WireEditionPage {
  return {
    editionVersion: "1",
    generationId,
    generatedAt: "2026-08-21T12:00:00.000Z",
    language: "en",
    source: "ranked",
    degraded: false,
    stories: [
      {
        itemId: `${generationId}-story`,
        canonicalUrl: "https://example.com/story",
        title,
        source: { name: "Example", domain: "example.com" },
        reasons: [],
        provenance: [],
      },
    ],
    topStoryIds: [`${generationId}-story`],
    publicationSpotlights: [],
    storyRails: [],
    people: [],
    trendingStoryIds: [],
  };
}

describe("The Wire edition cache", () => {
  it("replaces the complete generation instead of mixing old pagination", () => {
    const queryClient = new QueryClient();
    const key = WIRE_EDITION_QUERY_KEY("en", "baseline");
    queryClient.setQueryData<InfiniteData<WireEditionPage, string | undefined>>(
      key,
      {
        pages: [edition("old", "Old Lead"), edition("old", "Old Tail")],
        pageParams: [undefined, "old-cursor"],
      },
    );

    replaceWireEditionQueryGeneration(
      queryClient,
      "en",
      "baseline",
      edition("new", "New Lead"),
    );

    const cached = queryClient.getQueryData<
      InfiniteData<WireEditionPage, string | undefined>
    >(key);
    expect(cached?.pages).toHaveLength(1);
    expect(cached?.pages[0]?.generationId).toBe("new");
    expect(cached?.pages[0]?.stories[0]?.title).toBe("New Lead");
    expect(cached?.pageParams).toEqual([undefined]);
  });
});
