import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider, QueryObserver } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import React from "react";

import { useFeedReadAgeActions } from "@/hooks/useFeedReadAgeActions";
import * as AuthHook from "@/hooks/useAuth";
import * as ReadRouteContext from "@/contexts/ReadRouteContext";
import * as ReadAgeClient from "@/lib/feedReadAgeClient";
import type { GatewayMarkAllReadScope, PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import type { EntriesPage } from "@/hooks/useEntries";
import type { InfiniteData } from "@tanstack/react-query";

const viewerDid = "did:plc:viewer";
const before = "2026-09-02T05:00:00Z";
const scope: GatewayMarkAllReadScope = { kind: "publication", publicationId: "publication" };
const markEntriesRead = mock(() => {});
const restores: Array<() => void> = [];
let oauth: OAuthSession | null;
let currentViewer: string | null;

function sidebar(did = viewerDid): PublicationSidebarProjection {
  return {
    viewerDid: did,
    folders: [], publicationPrefs: [], allPublicationRows: [], myPublications: [],
    subscribedUnfoldered: [], followingTabPublications: [], enrollAuthorDids: [],
    refreshedAt: before,
    unreadCountsByPublicationId: { publication: 20, untouched: 9 },
  };
}

function entries(): InfiniteData<EntriesPage> {
  return {
    pages: [{ entries: [
      { entryId: "old", title: "Old", publishedAt: "2026-08-28T00:00:00Z", isRead: false },
      { entryId: "newer-deferred", title: "Newer", publishedAt: "2026-09-02T12:00:00Z", isRead: false },
    ] }],
    pageParams: [undefined],
  };
}

function confirmation(): ReadAgeClient.MarkReadBeforeResponse {
  return {
    marked: 2, entryIds: ["old", "uncached-old", "old"], readAt: before,
    unreadCounts: { publication: 18 },
  };
}

function pending<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

function harness(initialScope: GatewayMarkAllReadScope | null = scope) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
  const hook = renderHook(({ selectedScope }) => useFeedReadAgeActions(selectedScope), {
    wrapper, initialProps: { selectedScope: initialScope },
  });
  return { ...hook, queryClient };
}

beforeEach(() => {
  markEntriesRead.mockClear();
  currentViewer = viewerDid;
  oauth = { did: viewerDid } as unknown as OAuthSession;
  const auth = spyOn(AuthHook, "useAuth").mockImplementation(() => ({
    session: currentViewer ? { did: currentViewer } : null,
    getOAuthSession: () => oauth,
    oauthSessionReloadSeq: 0,
  }) as ReturnType<typeof AuthHook.useAuth>);
  const route = spyOn(ReadRouteContext, "useReadRoute").mockReturnValue({
    markEntriesRead,
  } as unknown as ReturnType<typeof ReadRouteContext.useReadRoute>);
  restores.push(() => auth.mockRestore(), () => route.mockRestore());
});

afterEach(() => {
  cleanup();
  for (const restore of restores.splice(0).reverse()) restore();
});

describe("useFeedReadAgeActions", () => {
  it("loads represented ages on demand with the browser's calendar time zone", async () => {
    const options = [{ days: 1, before, count: 12 }, { days: 4, before, count: 3 }];
    const fetch = spyOn(ReadAgeClient, "fetchReadAgeOptions")
      .mockResolvedValue({ referenceDay: before, options });
    restores.push(() => fetch.mockRestore());
    const { result } = harness();

    expect(fetch).not.toHaveBeenCalled();
    expect(await result.current.loadOptions()).toEqual(options);
    expect(fetch).toHaveBeenCalledWith(oauth, scope, Intl.DateTimeFormat().resolvedOptions().timeZone);
  });

  it("updates only confirmed IDs, preserving newer deferred rows and other viewers", async () => {
    const gateway = spyOn(ReadAgeClient, "markReadBefore").mockResolvedValue(confirmation());
    restores.push(() => gateway.mockRestore());
    const { queryClient, result } = harness();
    const key = ["entries", viewerDid, "publication", "all"];
    const otherKey = ["entries", "did:plc:other", "publication", "all"];
    queryClient.setQueryData(key, entries());
    queryClient.setQueryData(otherKey, entries());
    queryClient.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid), sidebar());
    queryClient.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("did:plc:other"), sidebar("did:plc:other"));

    await result.current.markBefore(before);

    expect(gateway).toHaveBeenCalledWith(oauth, scope, before);
    expect(markEntriesRead).toHaveBeenCalledWith(["old", "uncached-old"], { syncToAppView: false });
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(key)?.pages[0]?.entries).toEqual([
      { entryId: "old", title: "Old", publishedAt: "2026-08-28T00:00:00Z", isRead: true }, { entryId: "newer-deferred", title: "Newer", publishedAt: "2026-09-02T12:00:00Z", isRead: false },
    ]);
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(otherKey)).toEqual(entries());
    expect(queryClient.getQueryData<PublicationSidebarProjection>(
      PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid)
    )?.unreadCountsByPublicationId).toEqual({ publication: 18, untouched: 9 });
    expect(queryClient.getQueryData<PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("did:plc:other")))
      .toEqual(sidebar("did:plc:other"));
  });

  it("preserves unknown count keys and invalidates only the active viewer's unread feeds", async () => {
    const gateway = spyOn(ReadAgeClient, "markReadBefore")
      .mockResolvedValue({ ...confirmation(), unreadCounts: {} });
    restores.push(() => gateway.mockRestore());
    const { queryClient, result } = harness();
    const sidebarKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid);
    const unreadKey = ["entries", viewerDid, "publication", "unread"];
    const activeKey = ["aggregateEntries", viewerDid, "subscribed", "", "unread"];
    const otherKey = ["entries", "did:plc:other", "publication", "unread"];
    queryClient.setQueryData(sidebarKey, sidebar());
    for (const key of [unreadKey, activeKey, otherKey]) queryClient.setQueryData(key, entries());
    const fetch = mock(async () => entries());
    const observer = new QueryObserver(queryClient, { queryKey: activeKey, queryFn: fetch, staleTime: Infinity });
    const unsubscribe = observer.subscribe(() => {});
    restores.push(unsubscribe);

    await result.current.markBefore(before);

    expect(queryClient.getQueryData<PublicationSidebarProjection>(sidebarKey)).toEqual(sidebar());
    expect(queryClient.getQueryState(sidebarKey)?.isInvalidated).toBe(true);
    expect(queryClient.getQueryData(unreadKey)).toBeUndefined();
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(otherKey)).toEqual(entries());
    expect(queryClient.getQueryState(otherKey)?.isInvalidated).toBe(false);
  });

  it("does not modify local state or cache when the server fails", async () => {
    const gateway = spyOn(ReadAgeClient, "markReadBefore").mockRejectedValue(new Error("Unavailable"));
    restores.push(() => gateway.mockRestore());
    const { queryClient, result } = harness();
    const key = ["entries", viewerDid, "publication", "all"];
    queryClient.setQueryData(key, entries());

    await expect(result.current.markBefore(before)).rejects.toThrow("Unavailable");
    expect(markEntriesRead).not.toHaveBeenCalled();
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(entries());
  });

  it("restarts an active All feed's initial load after cancelling its stale request", async () => {
    const gateway = spyOn(ReadAgeClient, "markReadBefore").mockResolvedValue(confirmation());
    restores.push(() => gateway.mockRestore());
    const { queryClient, result } = harness();
    const key = ["entries", viewerDid, "publication", "all"];
    const staleRequest = pending<InfiniteData<EntriesPage>>();
    const refreshed = entries();
    refreshed.pages[0]!.entries[0]!.isRead = true;
    const fetch = mock(async () => refreshed).mockImplementationOnce(() => staleRequest.promise);
    const observer = new QueryObserver(queryClient, {
      queryKey: key,
      queryFn: fetch,
      refetchOnMount: false,
      refetchOnWindowFocus: false,
    });
    const unsubscribe = observer.subscribe(() => {});
    restores.push(unsubscribe);
    expect(queryClient.getQueryState(key)?.fetchStatus).toBe("fetching");

    await result.current.markBefore(before);

    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(queryClient.getQueryState(key)?.status).toBe("success"));
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(refreshed);
    staleRequest.resolve(entries());
    await staleRequest.promise;
    expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(refreshed);
  });

  for (const change of ["scope", "account", "session", "unmount"] as const) {
    it(`ignores a mutation response after ${change} changes`, async () => {
      const request = pending<ReadAgeClient.MarkReadBeforeResponse>();
      const gateway = spyOn(ReadAgeClient, "markReadBefore").mockReturnValue(request.promise);
      restores.push(() => gateway.mockRestore());
      const { result, rerender, unmount, queryClient } = harness();
      const key = ["entries", viewerDid, "publication", "all"];
      queryClient.setQueryData(key, entries());
      const operation = result.current.markBefore(before);
      if (change === "scope") rerender({ selectedScope: { kind: "following" } });
      if (change === "account") {
        currentViewer = "did:plc:other";
        oauth = { did: currentViewer } as unknown as OAuthSession;
        rerender({ selectedScope: scope });
      }
      if (change === "session") oauth = null;
      if (change === "unmount") unmount();
      request.resolve(confirmation());

      await expect(operation).rejects.toThrow("account or feed changed");
      expect(markEntriesRead).not.toHaveBeenCalled();
      expect(queryClient.getQueryData<InfiniteData<EntriesPage>>(key)).toEqual(entries());
    });
  }

  it("rejects stale age options after navigating to another feed", async () => {
    const request = pending<ReadAgeClient.ReadAgeOptionsResponse>();
    const fetch = spyOn(ReadAgeClient, "fetchReadAgeOptions").mockReturnValue(request.promise);
    restores.push(() => fetch.mockRestore());
    const { result, rerender } = harness();
    const operation = result.current.loadOptions();
    rerender({ selectedScope: { kind: "following" } });
    request.resolve({ referenceDay: before, options: [] });
    await expect(operation).rejects.toThrow("account or feed changed");
  });

  it("rejects unavailable authentication or scope before calling the server", async () => {
    const gateway = spyOn(ReadAgeClient, "markReadBefore").mockResolvedValue(confirmation());
    restores.push(() => gateway.mockRestore());
    const { result, rerender } = harness(null);
    await expect(result.current.markBefore(before)).rejects.toThrow("Sign in and select a feed");
    oauth = null;
    rerender({ selectedScope: scope });
    await expect(result.current.markBefore(before)).rejects.toThrow("Sign in and select a feed");
    expect(gateway).not.toHaveBeenCalled();
  });
});
