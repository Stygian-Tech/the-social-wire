import { afterEach, expect, it, spyOn } from "bun:test";
import { InfiniteQueryObserver, QueryClient } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as appview from "@/lib/thinAppViewClient";
import { readerRefreshRows, refreshPublicationSources } from "@/lib/refreshPublicationSources";
import type { PublicationSidebarProjection, SidebarPublicationRow } from "@/lib/publicationProjectionClient";

const oauthSession = {} as OAuthSession;
const row = (author: string, id = author): SidebarPublicationRow => ({ publicationId: id, authorDid: author, authorHandle: author, title: author, discoveredAt: "", appViewScope: { authorDid: author, publicationAtUri: null, publicationScopeAtUris: [], publicationSiteUrls: [] } });
let restore: (() => void) | undefined;
afterEach(() => restore?.());

it("awaits bounded deduplicated batches and paints before reporting completed progress", async () => {
  const calls: string[][] = [];
  const events: string[] = [];
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(async (_oauth, authors, feeds) => { calls.push([...authors, ...feeds ?? []]); events.push("enroll"); });
  restore = () => enroll.mockRestore();
  const rss = row("did:web:skyreader.rss", "rss");
  rss.appViewScope.publicationSiteUrls = ["https://feed.test/rss"];
  await refreshPublicationSources({ oauthSession, rows: [...Array.from({ length: 5 }, (_, i) => row(`did:plc:${i}`)), row("did:plc:0"), rss], signal: new AbortController().signal, onBatch: async () => { events.push("paint"); }, onProgress: (n, total) => { events.push(`${n}/${total}`); } });
  expect(calls.map(batch => batch.length)).toEqual([4, 2]);
  expect(calls[1]).toContain("https://feed.test/rss");
  expect(events).toEqual(["0/6", "enroll", "paint", "4/6", "enroll", "paint", "6/6"]);
});

it("paints partial results and continues other batches before reporting failure", async () => {
  let calls = 0;
  let paints = 0;
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(async () => { if (++calls === 1) throw new Error("upstream"); });
  restore = () => enroll.mockRestore();
  await expect(refreshPublicationSources({ oauthSession, rows: Array.from({ length: 6 }, (_, i) => row(`did:plc:${i}`)), signal: new AbortController().signal, onBatch: async () => { paints++; }, onProgress: () => {} })).rejects.toThrow("Some publications");
  expect(calls).toBe(2);
  expect(paints).toBe(2);
});

it("stops on cancellation without painting or starting another batch", async () => {
  const controller = new AbortController();
  let paints = 0;
  const enroll = spyOn(appview, "enrollAuthorsInAppView").mockImplementation(async () => { controller.abort(); });
  restore = () => enroll.mockRestore();
  await expect(refreshPublicationSources({ oauthSession, rows: Array.from({ length: 6 }, (_, i) => row(`did:plc:${i}`)), signal: controller.signal, onBatch: async () => { paints++; }, onProgress: () => {} })).rejects.toThrow();
  expect(enroll).toHaveBeenCalledTimes(1);
  expect(paints).toBe(0);
});

it("selects subscribed folders without enrolling the following graph or another viewer", () => {
  const client = new QueryClient();
  const subscribed = row("did:plc:subscribed"), folder = row("did:plc:folder"), following = row("did:plc:following");
  const projection: PublicationSidebarProjection = { viewerDid: "viewer", folders: [], publicationPrefs: [], allPublicationRows: [subscribed, folder, following], myPublications: [], subscribedUnfoldered: [subscribed], followingTabPublications: [following], folderSections: [{ folderRkey: "folder", folderUri: "at://folder", publications: [folder] }], enrollAuthorDids: [], refreshedAt: "" };
  const observer = new InfiniteQueryObserver(client, { queryKey: ["aggregateEntries", "viewer", "subscribed", "", "unread"], queryFn: async () => ({ entries: [] }), initialPageParam: undefined, getNextPageParam: () => undefined, staleTime: Infinity, initialData: { pages: [{ entries: [] }], pageParams: [undefined] } });
  const unsubscribe = observer.subscribe(() => {});
  expect(readerRefreshRows(client, "viewer", projection).map(row => row.publicationId)).toEqual([subscribed.publicationId, folder.publicationId]);
  expect(readerRefreshRows(client, "other-viewer", projection)).toEqual([]);
  unsubscribe(); client.clear();
});
