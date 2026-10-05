import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch, gatewayBaseUrl } from "@/lib/socialWireGatewayClient";
import { createOAuthAgent } from "@/lib/atprotoClient";
import type { SilenceInterval } from "./playback";
export type PodcastChapter = { startSeconds: number; title: string; artworkUrl?: string; url?: string };
export type PodcastPerson = { name: string; role?: string; imageUrl?: string; url?: string };
export type PodcastShow = {
  id: string;
  title: string;
  description?: string;
  artworkUrl?: string;
  hosts?: PodcastPerson[];
  feedUrl?: string;
  sourceKind: "rss" | "atproto" | "private-rss";
  visibility?: "public" | "private";
  sourceUri?: string;
  guid?: string;
  episodeCollection?: string;
  bridgeJobId?: string;
  bridgeStatus?: string;
};
export type PodcastTranscript = {
  url: string;
  type: string;
  language?: string;
  cues?: { startSeconds: number; endSeconds?: number; text: string }[];
  text?: string;
};
export type PodcastEpisode = {
  id: string;
  showId: string;
  title: string;
  description?: string;
  publishedAt: string;
  audioUrl: string;
  audioMimeType?: string;
  durationSeconds?: number;
  artworkUrl?: string;
  showArtworkUrl?: string;
  chapters?: PodcastChapter[];
  guid?: string;
  sourceUri?: string;
  visibility?: "public" | "private";
  transcripts: PodcastTranscript[];
};
export type PodcastProgress = {
  positionSeconds: number;
  updatedAt: string;
  completed: boolean;
};
export type PodcastState = {
  subscriptions: string[];
  queue: string[];
  progress: Record<string, PodcastProgress>;
  playbackSpeed: number;
  removeSilences: boolean;
  manualLinks: { rssShowId: string; protocolShowId: string }[];
};
export type PodcastStateEnvelope = { revision: number; state: PodcastState };
export type PodcastSilence = { status: string; intervals: SilenceInterval[]; analysisVersion?: string };
export type PodcastClip = {
  id: string;
  episodeId: string;
  startSeconds: number;
  endSeconds: number;
  title: string;
  status: string;
  jobId?: string;
  error?: string;
  audioUrl?: string;
  videoUrl?: string;
  publishedUri?: string;
  publicAudioUrl?: string;
  publicVideoUrl?: string;
  createdAt: string;
};
export const initialPodcastState = (): PodcastState => ({
  subscriptions: [],
  queue: [],
  progress: {},
  playbackSpeed: 1,
  removeSilences: false,
  manualLinks: [],
});
export class PodcastRevisionConflict extends Error {}
export async function podcastRequest<T>(
  oauth: OAuthSession,
  path: string,
  method = "GET",
  body?: unknown,
  signal?: AbortSignal,
): Promise<T> {
  const response = await gatewayFetch(oauth, `/v1/podcasts/${path}`, {
    method,
    signal,
    ...(body === undefined
      ? {}
      : {
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
  });
  if (response.status === 409)
    throw new PodcastRevisionConflict(
      "Listening state changed on another device. Refresh and retry your change.",
    );
  if (!response.ok) {
    let detail: string | undefined;
    try {
      const data = await response.json();
      const value = data.message ?? data.error;
      if (typeof value === "string") detail = value;
      else if (value && typeof value.message === "string") detail = value.message;
    } catch {}
    throw new Error(detail ?? `Podcasts request failed (${response.status})`);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}
export function podcastMediaPath(episodeId: string): string {
  return `media?episodeId=${encodeURIComponent(episodeId)}`;
}
export async function writePodcastSubscription(
  oauth: OAuthSession,
  viewer: string,
  show: PodcastShow,
  remove = false,
): Promise<void> {
  if (show.visibility === "private" || show.sourceKind === "private-rss") {
    if (!remove) throw new Error("Private feeds subscribe through the private RSS service");
    await podcastRequest(oauth, `private/subscriptions?showId=${encodeURIComponent(show.id)}`, "DELETE");
    return;
  }
  const agent = createOAuthAgent(oauth);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`podcast:${show.id}`),
  );
  const rkey = [...new Uint8Array(digest)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
  const collection = "app.skyreader.feed.subscription";
  if (remove) {
    await agent.com.atproto.repo.deleteRecord({
      repo: viewer,
      collection,
      rkey,
    });
    return;
  }
  const date = new Date().toISOString();
  const protocol = show.sourceUri?.match(/^at:\/\/([^/]+)\/([^/]+)\//);
  await agent.com.atproto.repo.putRecord({
    repo: viewer,
    collection,
    rkey,
    record: {
      $type: collection,
      createdAt: date,
      updatedAt: date,
      title: show.title,
      source: "the-social-wire",
      category: "podcast",
      ...(show.feedUrl
        ? { feedUrl: show.feedUrl, sourceType: "rss" }
        : {
            sourceType: "atproto.collection",
            subjectDid: protocol?.[1],
            collectionNsid: show.episodeCollection ?? protocol?.[2],
          }),
      ...(show.sourceUri ? { externalRef: show.sourceUri } : {}),
      ...(show.artworkUrl ? { customIconUrl: show.artworkUrl } : {}),
    },
  });
}
export async function publishPodcastClip(
  oauth: OAuthSession,
  viewer: string,
  clip: PodcastClip,
  episode: PodcastEpisode,
): Promise<string> {
  if (episode.visibility === "private") throw new Error("Private Feed Episodes Cannot Be Published");
  if (!clip.audioUrl || !clip.videoUrl)
    throw new Error("Wait for the clip exports to finish before publishing");
  const collection = "app.thesocialwire.podcast.clip";
  const rkey = clip.id;
  const result = await createOAuthAgent(oauth).com.atproto.repo.putRecord({
    repo: viewer,
    collection,
    rkey,
    record: {
      $type: collection,
      episodeId: episode.id,
      ...(episode.sourceUri ? { episodeUri: episode.sourceUri } : {}),
      title: clip.title,
      startMillis: Math.round(clip.startSeconds * 1000),
      endMillis: Math.round(clip.endSeconds * 1000),
      audioUrl:
        clip.publicAudioUrl ??
        `${gatewayBaseUrl()}/v1/podcasts/public/assets?clipId=${encodeURIComponent(clip.id)}&format=audio`,
      videoUrl:
        clip.publicVideoUrl ??
        `${gatewayBaseUrl()}/v1/podcasts/public/assets?clipId=${encodeURIComponent(clip.id)}&format=video`,
      sourceUrl: episode.audioUrl,
      createdAt: clip.createdAt,
    },
  });
  await podcastRequest(oauth, "clips/publish", "POST", {
    clipId: clip.id,
    uri: result.data.uri,
  });
  return result.data.uri;
}
export async function unpublishPodcastClip(
  oauth: OAuthSession,
  viewer: string,
  clip: PodcastClip,
): Promise<void> {
  if (clip.publishedUri) {
    const match = clip.publishedUri.match(/^at:\/\/([^/]+)\/([^/]+)\/([^/]+)$/);
    if (!match || match[1] !== viewer)
      throw new Error("This clip belongs to another account");
    await createOAuthAgent(oauth).com.atproto.repo.deleteRecord({
      repo: viewer,
      collection: match[2],
      rkey: match[3],
    });
  }
  await podcastRequest(
    oauth,
    `clips?clipId=${encodeURIComponent(clip.id)}`,
    "DELETE",
  );
}
export async function publicPodcastClip(
  uri: string,
): Promise<PodcastClip | null> {
  const response = await fetch(
    `${gatewayBaseUrl()}/v1/podcasts/public/clips?uri=${encodeURIComponent(uri)}`,
    { cache: "no-store" },
  );
  if (!response.ok) return null;
  return response.json() as Promise<PodcastClip>;
}
export const podcastClipPath = (uri: string) =>
  `/podcast-clips/${encodeURIComponent(uri)}`;
