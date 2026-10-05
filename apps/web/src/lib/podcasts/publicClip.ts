import "server-only";
import type { PodcastClip } from "./client";
export async function fetchPublicPodcastClip(
  id: string,
): Promise<PodcastClip | null> {
  const base = (
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL ??
    "https://api.thesocialwire.app"
  ).replace(/\/$/, "");
  const response = await fetch(
    `${base}/v1/podcasts/public/clips?clipId=${encodeURIComponent(id)}`,
    { cache: "no-store" },
  );
  return response.ok ? response.json() : null;
}
