import type { PodcastEpisode } from "./client";

export type PodcastFeed = "recent" | "downloads" | "queue" | "show" | "clips";

export function podcastFeedEpisodes(
  feed: PodcastFeed,
  episodes: PodcastEpisode[],
  downloads: PodcastEpisode[],
  queue: string[],
): PodcastEpisode[] {
  if (feed === "clips") return [];
  if (feed === "downloads") return downloads;
  if (feed !== "queue") return episodes;
  const available = new Map([...episodes, ...downloads].map((item) => [item.id, item]));
  return queue.flatMap((id) => {
    const item = available.get(id);
    return item ? [item] : [];
  });
}
