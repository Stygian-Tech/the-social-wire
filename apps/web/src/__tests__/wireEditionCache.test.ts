import { describe, expect, it } from "bun:test";
import { QueryClient, type InfiniteData } from "@tanstack/react-query";

import {
  replaceWireEditionQueryGeneration,
  WIRE_EDITION_REFRESH_INTERVAL_MS,
  WIRE_EDITION_REFRESH_POLICY,
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
  it("refreshes on mount and every five minutes while visible", () => {
    expect(WIRE_EDITION_REFRESH_INTERVAL_MS).toBe(5 * 60_000);
    expect(WIRE_EDITION_REFRESH_POLICY).toEqual({
      staleTime: 5 * 60_000,
      refetchInterval: 5 * 60_000,
      refetchIntervalInBackground: false,
      refetchOnMount: "always",
      refetchOnWindowFocus: "always",
    });
  });

  it("replaces the complete generation instead of mixing old pagination", () => {
    const queryClient = new QueryClient();
    const key = WIRE_EDITION_QUERY_KEY("en", "outside-us", "baseline");
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
      "outside-us",
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

  it("isolates persisted editions by coarse browser region", () => {
    expect(WIRE_EDITION_QUERY_KEY("en", "default", "baseline")).not.toEqual(
      WIRE_EDITION_QUERY_KEY("en", "outside-us", "baseline"),
    );
  });
});
