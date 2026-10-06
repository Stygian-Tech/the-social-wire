"use client";
import Link from "next/link";
import { Pause, Play } from "lucide-react";
import type { PlayerContext } from "./PodcastPlayerProvider";
import { activePodcastChapter } from "@/lib/podcasts/playback";
import { PodcastArtwork } from "./PodcastArtwork";
import { PodcastChapterTimeline } from "./PodcastChapterTimeline";
import { PodcastPlaybackDefaults } from "./PodcastPlaybackDefaults";
import { PodcastClipDialog } from "./PodcastClipDialog";

export function PodcastPlayerView({ player }: { player: PlayerContext }) {
  const episode = player.episode;
  if (!episode) return null;
  const chapter = activePodcastChapter(episode.chapters ?? [], player.position);
  const artwork = chapter?.artworkUrl ?? episode.artworkUrl ?? episode.showArtworkUrl;
  const artworkLabel = chapter?.artworkUrl ? `Chapter Artwork: ${chapter.title}` : `Episode Artwork: ${episode.title}`;
  const transport = <div aria-label="Playback Controls" className="flex items-center justify-center gap-1">
    <button type="button" aria-label="Back 15 Seconds" onClick={() => player.seek(player.position - 15)} className="min-h-11 min-w-11 rounded px-2 text-xs hover:bg-accent">−15</button>
    <button type="button" aria-label={player.playing ? "Pause" : "Play"} onClick={player.toggle} className="flex min-h-11 min-w-11 items-center justify-center rounded-full text-primary-foreground">
      <span className="flex size-8 items-center justify-center rounded-full bg-primary">{player.playing ? <Pause aria-hidden="true" className="size-4" /> : <Play aria-hidden="true" className="size-4" />}</span>
    </button>
    <button type="button" aria-label="Forward 30 Seconds" onClick={() => player.seek(player.position + 30)} className="min-h-11 min-w-11 rounded px-2 text-xs hover:bg-accent">+30</button>
  </div>;
  const title = <div className="min-w-0"><Link href="/podcasts" className="block truncate text-sm font-semibold">{episode.title}</Link>
    {chapter ? <p className="truncate text-xs text-muted-foreground">{chapter.title}</p> : null}</div>;
  const error = player.error ? <p role="alert" className="text-sm text-destructive">{player.error}<button type="button" className="ml-2 min-h-9 underline" onClick={player.clearError}>Dismiss</button></p> : null;
  return <aside aria-label="Podcast Player" className="relative z-20 shrink-0 border-t bg-background px-3 py-2">
    <div className="mx-auto grid max-w-7xl grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2 gap-y-1 md:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)]">
      <div className="flex min-w-0 items-center gap-2"><div className="size-10 shrink-0"><PodcastArtwork src={artwork} fallbackSources={[episode.artworkUrl, episode.showArtworkUrl]} alt={artworkLabel} size={40} /></div>{title}</div>
      {transport}
      <div className="col-span-2 flex min-w-0 flex-wrap items-center justify-center gap-x-3 gap-y-0 md:col-span-1 md:justify-end">
        <PodcastClipDialog key={episode.id} player={player} episode={episode} />
        <PodcastPlaybackDefaults player={player} />
      </div>
      <div className="col-span-2 min-w-0 md:col-span-3"><PodcastChapterTimeline chapters={episode.chapters ?? []} artworkSources={[episode.artworkUrl, episode.showArtworkUrl]} position={player.position} duration={player.duration || episode.durationSeconds || 0} seek={player.seek} /></div>
      {episode.visibility !== "private" && player.state.removeSilences && player.silence?.status !== "complete" ? <p className="col-span-2 text-xs md:col-span-3" role="status">Silence Analysis: {player.silence?.status ?? "Pending"}{player.silence?.status === "failed" || player.silence?.status === "unavailable" ? <button type="button" className="ml-2 min-h-9 underline" onClick={() => void player.setRemoveSilences(true)}>Retry Analysis</button> : null}</p> : null}
      {error ? <div className="col-span-2 md:col-span-3">{error}</div> : null}
    </div>
  </aside>;
}
