import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { BlueskySocialPage } from "./blueskySocialClient";
import { gatewayFetch } from "./socialWireGatewayClient";

export type MediaMode = "photos" | "short-videos";

/** The service selects media; the viewer-aware AppView owns discovery and cursors. */
export async function projectMediaPage(session: OAuthSession, page: BlueskySocialPage, mode: MediaMode, signal?: AbortSignal): Promise<BlueskySocialPage> {
  signal?.throwIfAborted();
  const response = await gatewayFetch(session, "/v1/media/project", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ mode, posts: page.feed.map(({ post }) => ({ uri: post.uri, embed: post.embed })) }),
    signal,
  });
  signal?.throwIfAborted();
  if (!response.ok) throw new Error("Live Media is unavailable. Please try again.");
  const result: unknown = await response.json();
  if (!result || typeof result !== "object" || !("uris" in result) || !Array.isArray(result.uris) || !result.uris.every(uri => typeof uri === "string")) {
    throw new Error("Live Media returned an invalid response. Please try again.");
  }
  const selected = new Set<string>(result.uris);
  return { ...page, feed: page.feed.filter(({ post }) => selected.has(post.uri)) };
}

/** Media deduplicates originals and reposts while preserving the upstream order. */
export function uniqueMediaPosts(pages: readonly BlueskySocialPage[]): BlueskySocialPage["feed"] {
  const seen = new Set<string>();
  return pages.flatMap(page => page.feed).filter(({ post }) => {
    if (seen.has(post.uri)) return false;
    seen.add(post.uri);
    return true;
  });
}
