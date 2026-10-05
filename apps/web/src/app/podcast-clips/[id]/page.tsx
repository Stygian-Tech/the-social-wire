import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { fetchPublicPodcastClip } from "@/lib/podcasts/publicClip";
import { podcastsEnabled } from "@/lib/podcasts/playback";
import { formatPodcastTime } from "@/lib/podcasts/playback";
type Props = { params: Promise<{ id: string }> };
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  if (!podcastsEnabled()) return {};
  const clip = await fetchPublicPodcastClip(id);
  if (!clip) return {};
  const base = process.env.NEXT_PUBLIC_SITE_URL ?? "https://thesocialwire.app";
  const url = `${base}/podcast-clips/${encodeURIComponent(id)}`;
  return {
    title: `${clip.title} | The Social Wire`,
    description: "Listen to this podcast clip and share its audiogram.",
    alternates: {
      canonical: url,
      types: {
        "application/json+oembed": `${base}/api/podcast-oembed?url=${encodeURIComponent(url)}`,
      },
    },
    openGraph: {
      title: clip.title,
      url,
      type: "video.other",
      ...(clip.videoUrl
        ? {
            videos: [
              { url: clip.publicVideoUrl ?? clip.videoUrl, type: "video/mp4" },
            ],
          }
        : {}),
    },
    twitter: { card: "summary_large_image", title: clip.title },
  };
}
export default async function PodcastClipPage({ params }: Props) {
  if (!podcastsEnabled()) notFound();
  const { id } = await params;
  const clip = await fetchPublicPodcastClip(id);
  if (!clip) notFound();
  return (
    <main className="mx-auto w-full max-w-2xl space-y-5 p-6">
      <a href="/podcasts" className="text-sm underline">
        Podcasts · The Social Wire
      </a>
      <h1 className="text-3xl font-semibold">{clip.title}</h1>
      <p className="text-sm text-muted-foreground">
        Original Episode: {formatPodcastTime(clip.startSeconds)}–
        {formatPodcastTime(clip.endSeconds)}
      </p>
      {clip.audioUrl ? (
        <audio
          controls
          preload="metadata"
          src={clip.publicAudioUrl ?? clip.audioUrl}
          className="w-full"
        />
      ) : null}
      {clip.videoUrl ? (
        <video
          controls
          preload="metadata"
          src={clip.publicVideoUrl ?? clip.videoUrl}
          className="w-full rounded-xl"
        />
      ) : null}
      <p className="text-sm">
        Shared from a publisher&apos;s podcast. Clip audio preserves the
        original playback speed and pauses.
      </p>
    </main>
  );
}
