import { describe, expect, it } from "bun:test";
import { renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import { ENTRIES_QUERY_KEY } from "@/hooks/useEntries";
import { useSidebarUnreadController } from "@/hooks/useSidebarUnreadController";
import { useSidebarUnreadCounts } from "@/hooks/useSidebarUnreadCounts";
import type { DiscoveredPublication, EntryListItem } from "@/lib/atprotoClient";

const pub: DiscoveredPublication = {
  publicationId: "did:plc:alice",
  subscriptionPublicationId: "did:plc:alice",
  authorDid: "did:plc:alice",
  authorHandle: "alice.test",
  title: "Alice",
  discoveredAt: "2026-01-01T00:00:00.000Z",
};

function renderWithClient<T>(callback: () => T) {
  const queryClient = new QueryClient();
  return renderHook(callback, {
    wrapper: ({ children }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    ),
  });
}

describe("useSidebarUnreadCounts", () => {
  it("maps API unread counts by publication id", () => {
    const unreadCountsByPublicationId = new Map([
      ["did:plc:alice", 3],
    ]);

    const { result } = renderWithClient(() =>
      useSidebarUnreadCounts([pub], unreadCountsByPublicationId)
    );

    expect(result.current.get("did:plc:alice")).toBe(3);
  });

  it("returns zero when no API counts are present", () => {
    const { result } = renderWithClient(() =>
      useSidebarUnreadCounts([pub], undefined)
    );

    expect(result.current.get("did:plc:alice")).toBe(0);
  });

  it("reconciles cached entries when readEpoch bumps", () => {
    const queryClient = new QueryClient();
    const entry: EntryListItem = {
      entryId: "at://did:plc:alice/site.standard.document/1",
      title: "One",
      publishedAt: "2026-01-01T00:00:00.000Z",
    };
    queryClient.setQueryData(ENTRIES_QUERY_KEY("did:plc:alice"), {
      pages: [{ entries: [entry], cursor: undefined }],
      pageParams: [undefined],
    });

    const unreadCountsByPublicationId = new Map([["did:plc:alice", 1]]);
    const readIds = new Set<string>();
    const isEntryRead = (id: string) => readIds.has(id);

    const { result, rerender } = renderHook(
      ({ readEpoch }: { readEpoch: number }) =>
        useSidebarUnreadController({
          publications: [pub],
          unreadCountsByPublicationId,
          isEntryRead,
          readEpoch,
        }),
      {
        initialProps: { readEpoch: 0 },
        wrapper: ({ children }) => (
          <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
        ),
      }
    );

    expect(result.current.get("did:plc:alice")).toBe(1);
    readIds.add(entry.entryId);
    rerender({ readEpoch: 1 });
    expect(result.current.get("did:plc:alice")).toBe(0);
  });
});
