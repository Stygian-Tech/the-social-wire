import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import { useCachedBulkReadActions } from "@/hooks/useCachedBulkReadActions";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { ENTRIES_QUERY_KEY } from "@/hooks/useEntries";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import * as AuthHook from "@/hooks/useAuth";
import * as ReadRouteContext from "@/contexts/ReadRouteContext";
import * as PublicationProjectionClient from "@/lib/publicationProjectionClient";

const markEntriesRead = mock(() => {});
const markEntriesUnread = mock(() => {});
const isEntryRead = mock((entryId: string) => entryId.length < 0);
let restoreHookSpies: (() => void) | undefined;

const pub: DiscoveredPublication = {
  publicationId: "did:plc:alice",
  subscriptionPublicationId: "did:plc:alice",
  authorDid: "did:plc:alice",
  authorHandle: "alice.test",
  title: "Alice",
  discoveredAt: "2026-01-01T00:00:00.000Z",
};
const viewerDid = "did:plc:viewer";

describe("useCachedBulkReadActions", () => {
  beforeEach(() => {
    markEntriesRead.mockClear();
    markEntriesUnread.mockClear();
    isEntryRead.mockClear();
    isEntryRead.mockImplementation(() => false);
    const readRouteSpy = spyOn(ReadRouteContext, "useReadRoute").mockReturnValue({
      markEntriesRead,
      markEntriesUnread,
      isEntryRead,
    } as unknown as ReturnType<typeof ReadRouteContext.useReadRoute>);
    const authSpy = spyOn(AuthHook, "useAuth").mockReturnValue({
      session: { did: viewerDid },
      getOAuthSession: () => null,
    } as ReturnType<typeof AuthHook.useAuth>);
    restoreHookSpies = () => {
      authSpy.mockRestore();
      readRouteSpy.mockRestore();
    };
  });

  afterEach(() => {
    cleanup();
    restoreHookSpies?.();
    restoreHookSpies = undefined;
  });

  it("keeps server-scoped bulk actions enabled when cache is empty", () => {
    const queryClient = new QueryClient();
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );

    const { result } = renderHook(
      () => useCachedBulkReadActions([pub]),
      { wrapper }
    );

    expect(result.current.bulkDisabled).toBe(false);
    expect(result.current.cachedEntryIds).toEqual([]);
  });

  it("marks cached entries read without per-entry AppView sync", () => {
    const queryClient = new QueryClient();
    const entryId = "at://did:plc:alice/site.standard.document/one";
    queryClient.setQueryData([...ENTRIES_QUERY_KEY(viewerDid, pub.publicationId), "all"], {
      pages: [
        {
          entries: [
            {
              entryId,
              title: "One",
              publishedAt: "2026-01-01T00:00:00.000Z",
            },
          ],
          cursor: undefined,
        },
      ],
      pageParams: [undefined],
    });

    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );

    const { result } = renderHook(() => useCachedBulkReadActions([pub]), {
      wrapper,
    });

    result.current.applyMarkAllRead();

    expect(markEntriesRead).toHaveBeenCalledWith([entryId], {
      publications: [pub],
      syncToAppView: false,
    });
  });

  it("restores the exact cache and read state when bulk persistence cannot start", () => {
    const queryClient = new QueryClient();
    const previouslyReadId = "at://did:plc:alice/site.standard.document/read";
    const newlyReadId = "at://did:plc:alice/site.standard.document/unread";
    isEntryRead.mockImplementation((entryId) => entryId === previouslyReadId);
    const queryKey = [
      ...ENTRIES_QUERY_KEY(viewerDid, pub.publicationId),
      "all",
    ] as const;
    queryClient.setQueryData(queryKey, {
      pages: [
        {
          entries: [
            {
              entryId: previouslyReadId,
              title: "Read",
              publishedAt: "2026-01-01T00:00:00.000Z",
              isRead: true,
            },
            {
              entryId: newlyReadId,
              title: "Unread",
              publishedAt: "2026-01-02T00:00:00.000Z",
              isRead: false,
            },
          ],
        },
      ],
      pageParams: [undefined],
    });
    const before = queryClient.getQueryData(queryKey);
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );
    const { result } = renderHook(() => useCachedBulkReadActions([pub]), { wrapper });

    result.current.applyMarkAllRead();

    expect(JSON.stringify(queryClient.getQueryData(queryKey))).toBe(
      JSON.stringify(before)
    );
    expect(markEntriesUnread).toHaveBeenCalledWith([newlyReadId], {
      publications: [pub],
    });
    expect(markEntriesRead).toHaveBeenLastCalledWith([previouslyReadId], {
      publications: [pub],
      syncToAppView: false,
    });
  });

  it("invalidates the sidebar projection cache once the gateway confirms mark-all-read", async () => {
    const queryClient = new QueryClient();
    // Simulate a stale persisted projection sitting in the cache — the bug this
    // guards against is this staying stale forever after a successful mark-all-read.
    queryClient.setQueryData(
      PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid),
      { stale: true }
    );
    const authSpy = spyOn(AuthHook, "useAuth").mockReturnValue({
      session: { did: viewerDid },
      getOAuthSession: () => ({}) as never,
    } as unknown as ReturnType<typeof AuthHook.useAuth>);
    const gatewaySpy = spyOn(
      PublicationProjectionClient,
      "markAllReadOnGateway"
    ).mockResolvedValue({} as never);

    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );
    const { result } = renderHook(
      () =>
        useCachedBulkReadActions([pub], {
          gatewayScopes: [{ kind: "subscribed" }],
        }),
      { wrapper }
    );

    result.current.applyMarkAllRead();

    await waitFor(() => expect(gatewaySpy).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(
        queryClient.getQueryState(
          PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid)
        )?.isInvalidated
      ).toBe(true)
    );

    authSpy.mockRestore();
    gatewaySpy.mockRestore();
  });

  it("marks entries that landed in cache mid-flight once the gateway confirms", async () => {
    const queryClient = new QueryClient();
    const lateEntryId = "at://did:plc:alice/site.standard.document/late";
    const authSpy = spyOn(AuthHook, "useAuth").mockReturnValue({
      session: { did: viewerDid },
      getOAuthSession: () => ({}) as never,
    } as unknown as ReturnType<typeof AuthHook.useAuth>);
    // Simulates a background prefetch landing while the gateway call is in flight —
    // this entry was never part of the synchronous cachedEntryIds snapshot.
    const gatewaySpy = spyOn(
      PublicationProjectionClient,
      "markAllReadOnGateway"
    ).mockImplementation(async () => {
      queryClient.setQueryData(
        [...ENTRIES_QUERY_KEY(viewerDid, pub.publicationId), "all"],
        {
          pages: [
            {
              entries: [
                {
                  entryId: lateEntryId,
                  title: "Late",
                  publishedAt: "2026-01-01T00:00:00.000Z",
                },
              ],
              cursor: undefined,
            },
          ],
          pageParams: [undefined],
        }
      );
      return {} as never;
    });

    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );
    const { result } = renderHook(
      () =>
        useCachedBulkReadActions([pub], {
          gatewayScopes: [{ kind: "subscribed" }],
        }),
      { wrapper }
    );

    result.current.applyMarkAllRead();

    await waitFor(() =>
      expect(markEntriesRead).toHaveBeenLastCalledWith([lateEntryId], {
        publications: [pub],
        syncToAppView: false,
      })
    );

    authSpy.mockRestore();
    gatewaySpy.mockRestore();
  });
});
