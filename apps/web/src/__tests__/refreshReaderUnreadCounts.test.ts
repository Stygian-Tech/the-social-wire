import { afterEach, expect, it, spyOn } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as appview from "@/lib/thinAppViewClient";
import { recordReadEntryMutations } from "@/lib/feedRefreshCoordinator";
import { refreshReaderUnreadCounts } from "@/lib/refreshReaderUnreadCounts";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";

let restore: (() => void) | undefined;
afterEach(() => restore?.());
const projection = (viewerDid: string): PublicationSidebarProjection => ({ viewerDid, folders: [], publicationPrefs: [], allPublicationRows: [], myPublications: [], subscribedUnfoldered: [], followingTabPublications: [], enrollAuthorDids: [], refreshedAt: "", unreadCountsByPublicationId: { a: 9, b: 4, unrelated: 7 } });
it("refreshes scoped badges after ingestion and zeros omitted sparse counts", async () => {
  const client = new QueryClient();
  const key = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("viewer");
  const other = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("other");
  client.setQueryData(key, projection("viewer"));
  client.setQueryData(other, projection("other"));
  const fetch = spyOn(appview, "fetchAppViewUnreadCounts").mockResolvedValue({ counts: { a: 12 } });
  restore = () => fetch.mockRestore();
  await refreshReaderUnreadCounts({ queryClient: client, viewerDid: "viewer", oauthSession: {} as OAuthSession, publicationIds: ["a", "b", "a"], signal: new AbortController().signal });
  expect(fetch.mock.calls[0]?.[1]).toEqual(["a", "b"]);
  expect(client.getQueryData<PublicationSidebarProjection>(key)?.unreadCountsByPublicationId).toEqual({ a: 12, b: 0, unrelated: 7 });
  expect(client.getQueryData<PublicationSidebarProjection>(other)?.unreadCountsByPublicationId?.a).toBe(9);
  client.clear();
});
it("bounds count request sizes and does not apply a response after cancellation", async () => {
  const client = new QueryClient();
  const key = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("viewer");
  client.setQueryData(key, projection("viewer"));
  const controller = new AbortController();
  const fetch = spyOn(appview, "fetchAppViewUnreadCounts").mockImplementation(async () => { controller.abort(); return { counts: { a: 99 } }; });
  restore = () => fetch.mockRestore();
  await expect(refreshReaderUnreadCounts({ queryClient: client, viewerDid: "viewer", oauthSession: {} as OAuthSession, publicationIds: Array.from({ length: 101 }, (_, i) => `${i}`), signal: controller.signal })).rejects.toThrow();
  expect(fetch.mock.calls[0]?.[1]).toHaveLength(50);
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(client.getQueryData<PublicationSidebarProjection>(key)?.unreadCountsByPublicationId?.a).toBe(9);
  client.clear();
});

it("preserves badge optimism when a read gesture supersedes a pending count snapshot", async () => {
  const client = new QueryClient();
  const session = {} as OAuthSession;
  const key = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("viewer");
  client.setQueryData(key, projection("viewer"));
  const fetch = spyOn(appview, "fetchAppViewUnreadCounts").mockImplementation(async () => {
    recordReadEntryMutations(client, session, ["article"]);
    client.setQueryData(key, { ...projection("viewer"), unreadCountsByPublicationId: { a: 0 } });
    return { counts: { a: 9 } };
  });
  restore = () => fetch.mockRestore();
  await refreshReaderUnreadCounts({ queryClient: client, viewerDid: "viewer", oauthSession: session, publicationIds: ["a"], signal: new AbortController().signal });
  expect(client.getQueryData<PublicationSidebarProjection>(key)?.unreadCountsByPublicationId).toEqual({ a: 0 });
  client.clear();
});
