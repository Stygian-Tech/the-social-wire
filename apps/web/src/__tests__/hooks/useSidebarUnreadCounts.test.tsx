import { describe, expect, it, mock } from "bun:test";
import { renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import { useSidebarUnreadCounts } from "@/hooks/useSidebarUnreadCounts";
import { ENTRIES_QUERY_KEY } from "@/hooks/useEntries";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

const pub: DiscoveredPublication = {
  publicationId: "did:plc:alice",
  subscriptionPublicationId: "did:plc:alice",
  authorDid: "did:plc:alice",
  authorHandle: "alice.test",
  title: "Alice",
  discoveredAt: "2026-01-01T00:00:00.000Z",
};

function wrapper(queryClient: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );
  };
}

describe("useSidebarUnreadCounts", () => {
  it("counts unread entries from query cache", () => {
    const queryClient = new QueryClient();
    queryClient.setQueryData(ENTRIES_QUERY_KEY("did:plc:alice"), {
      pages: [
        {
          entries: [
            { entryId: "at://did:plc:alice/site.standard.document/a", title: "A" },
            { entryId: "at://did:plc:alice/site.standard.document/b", title: "B" },
          ],
          cursor: undefined,
        },
      ],
      pageParams: [undefined],
    });

    const isEntryRead = (id: string) =>
      id === "at://did:plc:alice/site.standard.document/a";

    const { result } = renderHook(
      () => useSidebarUnreadCounts([pub], isEntryRead),
      { wrapper: wrapper(queryClient) }
    );

    expect(result.current.get("did:plc:alice")).toBe(1);
  });
});
