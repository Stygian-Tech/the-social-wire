import { AppBskyFeedPost, jsonToLex } from "@atproto/api";
import { expect, it } from "bun:test";
import { dehydrate, hydrate, QueryClient } from "@tanstack/react-query";
import { shouldPersistSocialQuery, prepareSocialQueryPersistence, restoreSocialQueryData } from "@/lib/socialQueryPersist";

const did = "did:plc:viewer";
const key = ["blueskySocial", did, "timeline", "cache-v1", "following", "", []];
const catalogKey = ["blueskySocial", did, "catalog", "cache-v1"];
const moderation = { userDid: did, prefs: { labelers: [] } };
it("persists only account-scoped timelines and matching moderation catalogs", () => {
  const client = new QueryClient();
  client.setQueryData(key, { pages: [{ feed: [] }], pageParams: [undefined] });
  client.setQueryData(catalogKey, { feeds: [], moderation });
  for (const surface of ["chat", "thread", "profile", "notifications"]) client.setQueryData(["blueskySocial", did, surface, "cache-v1"], { private: true });
  client.setQueryData(["blueskySocial", "", "catalog", "cache-v1"], { feeds: [], moderation });
  client.setQueryData(["blueskySocial", "did:plc:other", "catalog", "cache-v1"], { feeds: [], moderation });
  expect(dehydrate(client, { shouldDehydrateQuery: shouldPersistSocialQuery }).queries.map(q => q.queryKey)).toEqual([key, catalogKey]);
  client.clear();
});
it("restores bounded pages and cursors as stale data after a long scrolling session", () => {
  const source = new QueryClient();
  const data = { pages: Array.from({ length: 8 }, (_, i) => ({ feed: [{ post: { uri: `post-${i}` } }], cursor: `cursor-${i}` })), pageParams: [undefined, ...Array.from({ length: 7 }, (_, i) => `cursor-${i}`)] };
  source.setQueryData(key, data);
  source.setQueryData(catalogKey, { feeds: [], moderation });
  const snapshot = prepareSocialQueryPersistence({ timestamp: Date.now(), buster: "", clientState: dehydrate(source, { shouldDehydrateQuery: shouldPersistSocialQuery }) });
  const restored = new QueryClient();
  hydrate(restored, structuredClone(snapshot.clientState));
  expect(restored.getQueryData<typeof data>(key)).toEqual({ pages: data.pages.slice(0, 3), pageParams: data.pageParams.slice(0, 3) });
  expect(restored.getQueryData<{ feeds: unknown[]; moderation: typeof moderation }>(catalogKey)).toEqual({ feeds: [], moderation });
  expect(restored.getQueryState(key)?.dataUpdatedAt).toBe(1);
  expect(source.getQueryData<typeof data>(key)).toBe(data);
  expect(restored.getQueryData(["blueskySocial", "did:plc:other", ...key.slice(2)])).toBeUndefined();
  source.clear(); restored.clear();
});
it("keeps cached data after background errors and bounds remembered feeds", async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  for (let i = 0; i < 12; i++) client.setQueryData([...key.slice(0, 5), `feed-${i}`, []], { pages: [{ feed: [] }], pageParams: [undefined] });
  client.setQueryData(catalogKey, { feeds: [], moderation });
  await client.fetchQuery({ queryKey: catalogKey, queryFn: () => { throw new Error("Offline"); } }).catch(() => {});
  const snapshot = prepareSocialQueryPersistence({ timestamp: Date.now(), buster: "", clientState: dehydrate(client, { shouldDehydrateQuery: shouldPersistSocialQuery }) });
  expect(snapshot.clientState.queries).toHaveLength(11);
  expect(snapshot.clientState.queries.find(query => query.queryKey[2] === "catalog")?.state.data).toEqual({ feeds: [], moderation });
  client.clear();
});

it("rehydrates image record BlobRefs after an IndexedDB clone", () => {
  const record = jsonToLex({ $type: "app.bsky.feed.post", text: "Photo", createdAt: "2026-01-01T00:00:00Z", embed: { $type: "app.bsky.embed.images", images: [{ alt: "A mountain", image: { $type: "blob", ref: { $link: "bafkreigh2akiscaildcv6ubnt36d2bk6bj3fx3xpq6xfj2vgtz3yqjv2zy" }, mimeType: "image/jpeg", size: 11 } }] } });
  const client = new QueryClient();
  client.setQueryData(key, { pages: [{ feed: [{ post: { record } }] }], pageParams: [undefined] });
  const snapshot = prepareSocialQueryPersistence({ timestamp: Date.now(), buster: "", clientState: dehydrate(client, { shouldDehydrateQuery: shouldPersistSocialQuery }) });
  const restored = new QueryClient();
  hydrate(restored, structuredClone(snapshot.clientState), { defaultOptions: { deserializeData: restoreSocialQueryData } });
  const data = restored.getQueryData<{ pages: { feed: { post: { record: unknown } }[] }[] }>(key)!;
  expect(AppBskyFeedPost.validateRecord(data.pages[0].feed[0].post.record).success).toBe(true);
  expect((restored.getQueryData<{ pageParams: unknown[] }>(key))?.pageParams[0]).toBeUndefined();
  client.clear(); restored.clear();
});
