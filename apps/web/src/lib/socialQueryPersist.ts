import { jsonToLex, stringifyLex } from "@atproto/api";
import type { Query } from "@tanstack/react-query";
import type { PersistedClient } from "@tanstack/react-query-persist-client";
import type { BlueskySocialCatalog, BlueskySocialPage } from "./blueskySocialClient";

/** Only account-scoped timeline pages and their moderation/catalog snapshot go to disk. */
export function shouldPersistSocialQuery(query: { queryKey: Query["queryKey"]; state: Pick<Query["state"], "data"> }): boolean {
  const [namespace, did, surface, version] = query.queryKey;
  if (namespace !== "blueskySocial" || typeof did !== "string" || !did.startsWith("did:") || version !== "cache-v1") return false;
  if (surface === "catalog") {
    const data = query.state.data as BlueskySocialCatalog | undefined;
    return data?.moderation?.userDid === did && Array.isArray(data.feeds);
  }
  if (surface !== "timeline") return false;
  const data = query.state.data as { pages?: BlueskySocialPage[]; pageParams?: unknown[] } | undefined;
  return !!data?.pages?.length && Array.isArray(data.pageParams) && data.pages.slice(0, 3).every(page => Array.isArray(page.feed) && page.feed.length <= 50);
}

/** Keep the first three complete pages/cursors, even after a long scrolling session. */
export function prepareSocialQueryPersistence(client: PersistedClient): PersistedClient {
  const social = client.clientState.queries.filter(query => shouldPersistSocialQuery(query))
    .sort((a, b) => b.state.dataUpdatedAt - a.state.dataUpdatedAt);
  // Bound the number of remembered feeds as well as their pages.
  const keep = new Set(social.filter(query => query.queryKey[2] === "timeline").slice(0, 10));
  return { ...client, clientState: { ...client.clientState, queries: client.clientState.queries.flatMap(query => {
    if (!shouldPersistSocialQuery(query)) return [query];
    if (query.queryKey[2] === "catalog") return [{ ...query, state: { ...query.state, dataUpdatedAt: 1 } }];
    if (!keep.has(query)) return [];
    const data = query.state.data as { pages: BlueskySocialPage[]; pageParams: unknown[] };
    return [{ ...query, state: { ...query.state, dataUpdatedAt: 1, data: { ...data, pages: data.pages.slice(0, 3).map(page => JSON.parse(stringifyLex(page))), pageParams: data.pageParams.slice(0, 3) } } }];
  }) } };
}

/** IndexedDB structured cloning cannot preserve SDK BlobRef/CID prototypes. */
export function restoreSocialQueryData(data: unknown): unknown {
  const value = data as { pages?: BlueskySocialPage[] } | undefined;
  if (!value?.pages?.length || !value.pages.every(page => Array.isArray(page.feed))) return data;
  try { return { ...value, pages: value.pages.map(page => jsonToLex(page)) }; }
  catch { return data; } // Invalid records are still rejected by normal feed validation.
}
