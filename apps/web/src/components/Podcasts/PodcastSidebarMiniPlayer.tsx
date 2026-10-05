"use client";

import { Popover } from "@base-ui/react/popover";
import { Pause, Play, X } from "lucide-react";
import type { RefObject } from "react";
import type { PlayerContext } from "./PodcastPlayerProvider";
import { PodcastArtwork } from "./PodcastArtwork";
import { PodcastSeekBar } from "./PodcastSeekBar";
import { activePodcastChapter, clampPlaybackTime } from "@/lib/podcasts/playback";

function timeLabel(seconds: number) {
  const value = Math.max(0, Math.floor(seconds));
  return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
}

export function PodcastSidebarMiniPlayer({ player, anchor }: {
  player: PlayerContext;
  anchor: RefObject<HTMLLIElement | null>;
}) {
  const episode = player.episode;
  if (!episode) return null;
  const chapter = activePodcastChapter(episode.chapters ?? [], player.position);
  const artwork = chapter?.artworkUrl ?? episode.artworkUrl ?? episode.showArtworkUrl;
  const duration = player.duration || episode.durationSeconds || 0;
  const position = clampPlaybackTime(player.position, duration);
  return <Popover.Portal>
    <Popover.Positioner anchor={anchor} side="right" align="center" sideOffset={8} collisionPadding={12} className="z-[60]">
      <Popover.Popup aria-label="Podcast Mini Player" initialFocus={false} className="w-[min(20rem,calc(100vw-1.5rem))] rounded-xl border bg-background p-3 shadow-lg">
        <div className="flex items-start gap-3">
          <PodcastArtwork src={artwork} fallbackSources={[episode.artworkUrl, episode.showArtworkUrl]} alt={chapter?.artworkUrl ? `Chapter Artwork: ${chapter.title}` : `Episode Artwork: ${episode.title}`} size={56} />
          <div className="min-w-0 flex-1">
            <h3 className="line-clamp-2 text-sm font-semibold">{episode.title}</h3>
            {chapter ? <p className="mt-1 truncate text-xs text-muted-foreground">{chapter.title}</p> : null}
          </div>
          <Popover.Close aria-label="Close Podcast Controls" className="-mr-1 -mt-1 flex min-h-8 min-w-8 items-center justify-center rounded hover:bg-accent pointer-coarse:min-h-11 pointer-coarse:min-w-11"><X aria-hidden="true" className="size-4" /></Popover.Close>
        </div>
        <div className="mt-2 flex items-center gap-2">
          <button type="button" aria-label={player.playing ? "Pause Podcast" : "Play Podcast"} onClick={player.toggle} className="flex min-h-11 min-w-11 items-center justify-center rounded-full bg-primary text-primary-foreground">{player.playing ? <Pause aria-hidden="true" className="size-4" /> : <Play aria-hidden="true" className="size-4" />}</button>
          <div className="min-w-0 flex-1">
            <PodcastSeekBar position={position} duration={duration} seek={player.seek} label="Seek Podcast From Sidebar" />
            <p className="flex justify-between text-xs tabular-nums text-muted-foreground"><span>{timeLabel(position)}</span><span>{timeLabel(duration)}</span></p>
          </div>
        </div>
      </Popover.Popup>
    </Popover.Positioner>
  </Popover.Portal>;
}
