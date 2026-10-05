import { notFound } from "next/navigation";
import { fetchPublicPodcastClip } from "@/lib/podcasts/publicClip";
import { podcastsEnabled } from "@/lib/podcasts/playback";
export default async function PodcastClipEmbed({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  if (!podcastsEnabled()) notFound();
  const { id } = await params;
  const clip = await fetchPublicPodcastClip(id);
  if (!clip) notFound();
  return (
    <main className="space-y-3 rounded-xl border p-4">
      <a
        href={`/podcast-clips/${encodeURIComponent(id)}`}
        target="_blank"
        rel="noreferrer"
        className="font-semibold"
      >
        {clip.title}
      </a>
      {clip.audioUrl ? (
        <audio
          controls
          preload="metadata"
          src={clip.publicAudioUrl ?? clip.audioUrl}
          className="w-full"
        />
      ) : null}
      <p className="text-xs text-muted-foreground">
        Podcast Clip · The Social Wire
      </p>
    </main>
  );
}
