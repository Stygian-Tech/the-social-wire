"use client";
import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Maximize2, Minimize2, Pause, Play } from "lucide-react";
import type { PlayerContext } from "./PodcastPlayerProvider";
import { activePodcastChapter, PODCAST_SPEEDS } from "@/lib/podcasts/playback";
import { PodcastSelect } from "./PodcastSelect";
import { PodcastArtwork } from "./PodcastArtwork";
import { PodcastChapterTimeline } from "./PodcastChapterTimeline";

export function PodcastPlayerView({ player }: { player: PlayerContext }) {
  const [minimized, setMinimized] = useState(false);
  const [showControls, setShowControls] = useState(false);
  const playerElement = useRef<HTMLElement | null>(null);
  useEffect(() => {
    const root = document.documentElement;
    const clear = () => root.style.removeProperty("--podcast-player-height");
    const element = playerElement.current;
    if (!element) { clear(); return clear; }
    let active = true;
    const measure = () => {
      if (!active) return;
      const rect = element.getBoundingClientRect();
      // Include the gap occupied by mobile navigation and the safe-area inset.
      const occupied = rect.height > 0 ? rect.height + Math.max(0, window.innerHeight - rect.bottom) : 0;
      root.style.setProperty("--podcast-player-height", `${Math.ceil(occupied)}px`);
    };
    measure();
    const observer = typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : undefined;
    observer?.observe(element);
    window.addEventListener("resize", measure);
    return () => { active = false; observer?.disconnect(); window.removeEventListener("resize", measure); clear(); };
  }, [minimized, player.episode?.id]);
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
  if (minimized) return <aside ref={playerElement} aria-label="Podcast Player" className="group fixed right-3 bottom-[calc(4.75rem+env(safe-area-inset-bottom))] z-50 md:bottom-4">
    <div className="relative size-20 rounded-xl border bg-background p-1 shadow-lg">
      <button type="button" aria-label="Show Podcast Controls" aria-expanded={showControls} onClick={() => setShowControls(true)} className="size-full rounded-lg focus-visible:outline-2 focus-visible:outline-ring">
        <PodcastArtwork src={artwork} fallbackSources={[episode.artworkUrl, episode.showArtworkUrl]} alt={artworkLabel} size={80} />
      </button>
      <button type="button" aria-label="Restore Player" title="Restore Player" onClick={() => { setMinimized(false); setShowControls(false); }} className="absolute -top-3 -right-2 flex min-h-11 min-w-11 items-center justify-center rounded-full border bg-background shadow-sm"><Maximize2 aria-hidden="true" className="size-4" /></button>
    </div>
    <div className={`${showControls ? "flex" : "hidden"} absolute right-full bottom-0 mr-3 w-[min(20rem,calc(100vw-7rem))] flex-col gap-3 rounded-xl border bg-background p-3 shadow-lg group-hover:flex group-focus-within:flex`}>
      {title}{transport}{error}
    </div>
  </aside>;
  return <aside ref={playerElement} aria-label="Podcast Player" className="fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom))] z-50 border-t bg-background px-3 py-2 shadow-lg md:bottom-0">
    <div className="mx-auto grid max-w-7xl grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2 gap-y-1 md:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)]">
      <div className="flex min-w-0 items-center gap-2"><div className="size-8 shrink-0 sm:size-10"><PodcastArtwork src={artwork} fallbackSources={[episode.artworkUrl, episode.showArtworkUrl]} alt={artworkLabel} size={40} /></div>{title}</div>
      {transport}
      <div className="col-span-2 flex min-w-0 flex-wrap items-center justify-center gap-x-3 gap-y-0 md:col-span-1 md:justify-end">
        <label className="flex items-center gap-2 text-xs">Speed<PodcastSelect aria-label="Playback Speed" value={player.state.playbackSpeed} onChange={(event) => void player.changeState({ playbackSpeed: Number(event.target.value) })} className="min-h-8 rounded border bg-background px-2 py-1 pointer-coarse:min-h-11">
          {PODCAST_SPEEDS.map((speed) => <option key={speed} value={speed}>{speed}×</option>)}
        </PodcastSelect></label>
        <label className="flex min-h-8 items-center gap-2 text-xs pointer-coarse:min-h-11"><input type="checkbox" disabled={episode.visibility === "private"} checked={episode.visibility === "private" ? false : player.state.removeSilences} onChange={(event) => void player.setRemoveSilences(event.target.checked)} />Remove Silences</label>
        <button type="button" aria-label="Minimize Player" title="Minimize Player" onClick={() => setMinimized(true)} className="flex min-h-8 min-w-8 items-center justify-center rounded hover:bg-accent pointer-coarse:min-h-11 pointer-coarse:min-w-11"><Minimize2 aria-hidden="true" className="size-4" /></button>
      </div>
      <div className="col-span-2 min-w-0 md:col-span-3"><PodcastChapterTimeline chapters={episode.chapters ?? []} artworkSources={[episode.artworkUrl, episode.showArtworkUrl]} position={player.position} duration={player.duration || episode.durationSeconds || 0} seek={player.seek} /></div>
      {episode.visibility !== "private" && player.state.removeSilences && player.silence?.status !== "complete" ? <p className="col-span-2 text-xs md:col-span-3" role="status">Silence Analysis: {player.silence?.status ?? "Pending"}{player.silence?.status === "failed" || player.silence?.status === "unavailable" ? <button type="button" className="ml-2 min-h-9 underline" onClick={() => void player.setRemoveSilences(true)}>Retry Analysis</button> : null}</p> : null}
      {error ? <div className="col-span-2 md:col-span-3">{error}</div> : null}
    </div>
  </aside>;
}
