import { describe, expect, it, mock } from "bun:test";
import { renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import { useCachedBulkReadActions } from "@/hooks/useCachedBulkReadActions";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

mock.module("@/contexts/ReadRouteContext", () => ({
  useReadRoute: () => ({
    markEntriesRead: mock(() => {}),
    markEntriesUnread: mock(() => {}),
  }),
}));

mock.module("@/hooks/useEntriesCacheEpoch", () => ({
  useEntriesCacheEpoch: () => 0,
}));

const pub: DiscoveredPublication = {
  publicationId: "did:plc:alice",
  subscriptionPublicationId: "did:plc:alice",
  authorDid: "did:plc:alice",
  authorHandle: "alice.test",
  title: "Alice",
  discoveredAt: "2026-01-01T00:00:00.000Z",
};

describe("useCachedBulkReadActions", () => {
  it("disables bulk actions when cache is empty", () => {
    const queryClient = new QueryClient();
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );

    const { result } = renderHook(
      () => useCachedBulkReadActions([pub]),
      { wrapper }
    );

    expect(result.current.bulkDisabled).toBe(true);
    expect(result.current.cachedEntryIds).toEqual([]);
  });
});
