import { AppBskyActorDefs, type AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";

const writes = new Map<string, Promise<unknown>>();
export function serializeSocialPreferences<T>(session: OAuthSession, write: () => Promise<T>): Promise<T> {
  const next = (writes.get(session.did) ?? Promise.resolve()).catch(() => undefined).then(write);
  writes.set(session.did, next);
  const cleanup = () => { if (writes.get(session.did) === next) writes.delete(session.did); };
  void next.then(cleanup, cleanup);
  return next;
}
export async function getSocialFeedDirectory(session: OAuthSession, query: string, cursor?: string, signal?: AbortSignal, moderation?: ModerationOpts) {
  const agent = createAuthenticatedAppViewAgent(session);
  agent.configureLabelers(moderation?.prefs.labelers.map(item => item.did) ?? []);
  return query.trim()
    ? (await agent.app.bsky.unspecced.getPopularFeedGenerators({ query: query.trim(), cursor, limit: 30 }, { signal })).data
    : (await agent.app.bsky.feed.getSuggestedFeeds({ cursor, limit: 30 }, { signal })).data;
}
export type SavedFeedAction = "save" | "pin" | "unpin" | "remove";
/** Read fresh raw preferences inside the queue; retain every unrelated and future preference. */
export function changeSocialSavedFeed(session: OAuthSession, uri: string, action: SavedFeedAction, type: "feed" | "list" = "feed") {
  if (!new RegExp(`^at://did:[^/]+/${type === "feed" ? "app\\.bsky\\.feed\\.generator" : "app\\.bsky\\.graph\\.list"}/[^/?#]+$`).test(uri)) throw new Error("Invalid feed URI.");
  return serializeSocialPreferences(session, async () => {
    const agent = createAuthenticatedAppViewAgent(session);
    const { data } = await agent.app.bsky.actor.getPreferences({});
    const v2 = data.preferences.findLast(AppBskyActorDefs.isSavedFeedsPrefV2);
    const legacy = data.preferences.findLast(AppBskyActorDefs.isSavedFeedsPref);
    const previous = v2?.items ?? [{ id: crypto.randomUUID(), type: "timeline", value: "following", pinned: true }, ...Array.from(new Set([...(legacy?.pinned ?? []), ...(legacy?.saved ?? [])])).map(value => ({ id: crypto.randomUUID(), type: value.includes("/app.bsky.graph.list/") ? "list" : "feed", value, pinned: legacy?.pinned.includes(value) ?? false }))];
    const matches = previous.filter(item => item.type === type && item.value === uri);
    let items = previous.filter(item => item.type !== type || item.value !== uri);
    if (action === "save" && matches.length) {
      // An idempotent Save must not reorder an existing saved or pinned feed.
      let retained = false;
      items = previous.filter(item => {
        if (item.type !== type || item.value !== uri) return true;
        if (retained) return false;
        retained = true; return true;
      });
    } else if (action !== "remove") items = [...items, { ...(matches[0] ?? { id: crypto.randomUUID(), type, value: uri }), pinned: action === "pin" }];
    if (action !== "save" || !matches.length) items.sort((a, b) => Number(b.pinned) - Number(a.pinned));
    const preferences = data.preferences.filter(pref => pref.$type !== "app.bsky.actor.defs#savedFeedsPrefV2" && pref.$type !== "app.bsky.actor.defs#savedFeedsPref");
    preferences.push({ ...v2, $type: "app.bsky.actor.defs#savedFeedsPrefV2", items });
    // Keep legacy clients in sync as well; removing a feed must remove its legacy entry.
    if (data.preferences.some(pref => pref.$type === "app.bsky.actor.defs#savedFeedsPref")) preferences.push({ ...legacy, $type: "app.bsky.actor.defs#savedFeedsPref", saved: items.filter(item => item.type === "feed" || item.type === "list").map(item => item.value), pinned: items.filter(item => item.pinned && (item.type === "feed" || item.type === "list")).map(item => item.value) });
    await agent.app.bsky.actor.putPreferences({ preferences });
  });
}

export async function getSocialSavedGenerators(session: OAuthSession, signal?: AbortSignal) {
  const agent = createAuthenticatedAppViewAgent(session);
  const preferences = await agent.getPreferences();
  agent.configureLabelers(preferences.moderationPrefs.labelers.map(item => item.did));
  const uris = [...new Set(preferences.savedFeeds.filter(item => item.type === "feed").map(item => item.value))];
  const feeds: AppBskyFeedDefs.GeneratorView[] = [];
  for (let offset = 0; offset < uris.length; offset += 25) feeds.push(...(await agent.app.bsky.feed.getFeedGenerators({ feeds: uris.slice(offset, offset + 25) }, { signal })).data.feeds);
  return feeds;
}
