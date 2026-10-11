import { Agent, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getSocialFeedDirectory } from "@/lib/socialFeedDirectoryClient";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { LocalAppViewAgent } from "@/lib/localAppViewAgent";

function discoveryAgent() {
  const network = getAtprotoNetwork();
  const agent = network.appLabelers === undefined ? new Agent(network.publicAppView) : new LocalAppViewAgent(network.publicAppView, network.appLabelers);
  return agent;
}

/** Public topics intentionally omit viewer identity and OAuth credentials. */
export async function getSocialTrendingTopics(signal?: AbortSignal) {
  return (await discoveryAgent().app.bsky.unspecced.getTrendingTopics({ limit: 10 }, { signal })).data;
}

/** Existing viewer proxy reads retain block/mute context without new grants. */
export async function getSocialRecommendedFeeds(session: OAuthSession, moderation: ModerationOpts, signal?: AbortSignal) {
  if (moderation.userDid !== session.did) throw new Error("Your account changed. Please reload this page.");
  return (await getSocialFeedDirectory(session, "", undefined, signal, moderation)).feeds.slice(0, 6);
}

/** Bluesky may provide a compound search query in its native topic link. */
export function socialTrendingSearch(topic: { topic: string; link: string }): string {
  try {
    const url = new URL(topic.link, "https://bsky.app");
    if (url.origin === "https://bsky.app" && url.pathname === "/search") {
      const query = url.searchParams.get("q")?.trim();
      if (query && query.length <= 500) return query;
    }
  } catch { /* Topic text remains a safe local search fallback. */ }
  return topic.topic.slice(0, 500);
}
