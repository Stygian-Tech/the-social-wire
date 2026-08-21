import { describe, expect, it } from "bun:test";
import {
  QueryClient,
  QueryObserver,
  type InfiniteData,
} from "@tanstack/react-query";

import {
  IDLE_WIRE_REFRESH_STATUS,
  replaceWireQueryGeneration,
  setWireRefreshStatus,
  WIRE_ENTRIES_QUERY_KEY,
  WIRE_REFRESH_STATUS_QUERY_KEY,
  type WireRefreshStatus,
} from "@/hooks/useWireFeed";
import type { WireEntriesPage } from "@/lib/wireFeedClient";

function page(generationId: string, title: string, cursor?: string): WireEntriesPage {
  return {
    entries: [
      {
        entryId: `wire:${generationId}:${title}`,
        title,
        publishedAt: "2026-08-20T12:00:00.000Z",
      },
    ],
    cursor,
    generationId,
    generatedAt: "2026-08-20T12:00:00.000Z",
    language: "en",
    source: "ranked",
    degraded: false,
  };
}

describe("The Wire query cache", () => {
  it("replaces the entire ranked generation instead of mixing old cursors", () => {
    const queryClient = new QueryClient();
    queryClient.setQueryData<InfiniteData<WireEntriesPage, string | undefined>>(
      WIRE_ENTRIES_QUERY_KEY("en", "baseline"),
      {
        pages: [page("old", "Old first", "old-cursor"), page("old", "Old tail")],
        pageParams: [undefined, "old-cursor"],
      },
    );

    replaceWireQueryGeneration(
      queryClient,
      "en",
      "baseline",
      page("new", "New first", "new-cursor"),
    );

    const cached = queryClient.getQueryData<
      InfiniteData<WireEntriesPage, string | undefined>
    >(WIRE_ENTRIES_QUERY_KEY("en", "baseline"));
    expect(cached?.pages).toHaveLength(1);
    expect(cached?.pages[0]?.generationId).toBe("new");
    expect(cached?.pages[0]?.entries[0]?.title).toBe("New first");
    expect(cached?.pageParams).toEqual([undefined]);
  });

  it("isolates public baseline pages from viewer-moderated pages", () => {
    expect(WIRE_ENTRIES_QUERY_KEY("en", "baseline")).not.toEqual(
      WIRE_ENTRIES_QUERY_KEY("en", "viewer:did:plc:alice"),
    );
    expect(WIRE_ENTRIES_QUERY_KEY("en", "checking:did:plc:alice")).not.toEqual(
      WIRE_ENTRIES_QUERY_KEY("en", "baseline"),
    );
  });

  it("shares cached-page refresh failures with separate query observers", () => {
    const queryClient = new QueryClient();
    const queryKey = WIRE_REFRESH_STATUS_QUERY_KEY(
      "en",
      "viewer:did:plc:alice",
    );
    const headerObserver = new QueryObserver<WireRefreshStatus>(queryClient, {
      queryKey,
      queryFn: async () => IDLE_WIRE_REFRESH_STATUS,
      initialData: IDLE_WIRE_REFRESH_STATUS,
      enabled: false,
    });
    const updates: WireRefreshStatus[] = [];
    const unsubscribe = headerObserver.subscribe((result) => {
      if (result.data) updates.push(result.data);
    });
    const proofError = new Error("PDS DPoP nonce unavailable");

    setWireRefreshStatus(
      queryClient,
      "en",
      "viewer:did:plc:alice",
      { isPending: false, error: proofError },
    );

    expect(headerObserver.getCurrentResult().data).toEqual({
      isPending: false,
      error: proofError,
    });
    expect(updates.at(-1)?.error).toBe(proofError);

    setWireRefreshStatus(
      queryClient,
      "en",
      "viewer:did:plc:alice",
      IDLE_WIRE_REFRESH_STATUS,
    );
    expect(headerObserver.getCurrentResult().data).toEqual(
      IDLE_WIRE_REFRESH_STATUS,
    );
    unsubscribe();
  });
});
