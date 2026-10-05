"use client";
import { useState } from "react";
import type { PodcastChapter } from "@/lib/podcasts/client";
import { clampPlaybackTime, formatPodcastTime, orderedPodcastChapters } from "@/lib/podcasts/playback";
import { PodcastArtwork } from "./PodcastArtwork";

export function PodcastChapterTimeline({ chapters, artworkSources = [], duration, position, seek }: {
  chapters: PodcastChapter[];
  artworkSources?: (string | undefined)[];
  duration: number;
  position: number;
  seek: (seconds: number) => void;
}) {
  const [preview, setPreview] = useState<number | null>(null);
  const valid = orderedPodcastChapters(chapters, duration);
  const hovered = preview === null ? undefined : valid[preview];
  return <div className="min-w-0 space-y-1">
    {valid.length && duration > 0 ? <div aria-label="Chapter Markers" className="relative mx-3 h-11">
      {duration > 0 ? valid.map((chapter, index) => <button key={`${chapter.startSeconds}:${index}`} type="button"
        aria-label={`Seek to Chapter: ${chapter.title}, ${formatPodcastTime(chapter.startSeconds)}`}
        aria-describedby={preview === index ? "podcast-chapter-preview" : undefined}
        onMouseEnter={() => setPreview(index)} onMouseLeave={(event) => { if (!event.currentTarget.matches(":focus")) setPreview(null); }}
        onFocus={() => setPreview(index)} onBlur={() => setPreview(null)}
        onClick={() => { setPreview(index); seek(chapter.startSeconds); }}
        style={{ left: `${Math.min(100, chapter.startSeconds / duration * 100)}%` }}
        className="absolute top-0 flex h-11 w-11 -translate-x-1/2 items-center justify-center rounded focus-visible:outline-2 focus-visible:outline-ring">
        <span className="h-3 w-0.5 bg-primary" aria-hidden="true" />
      </button>) : null}
      {hovered ? <div id="podcast-chapter-preview" role="tooltip" className="absolute bottom-full left-1/2 z-10 mb-1 flex w-60 max-w-full -translate-x-1/2 items-center gap-3 rounded-lg border bg-background p-3 shadow-lg">
        {hovered.artworkUrl || artworkSources.some(Boolean) ? <div className="size-12 shrink-0"><PodcastArtwork key={hovered.artworkUrl} src={hovered.artworkUrl ?? artworkSources.find(Boolean)} fallbackSources={artworkSources} alt={`Chapter Artwork: ${hovered.title}`} size={48} /></div> : null}
        <div className="min-w-0"><p className="break-words text-sm font-medium">{hovered.title}</p><p className="text-xs text-muted-foreground">{formatPodcastTime(hovered.startSeconds)}</p></div>
      </div> : null}
    </div> : null}
    <input aria-label="Seek Podcast" type="range" min={0} max={duration} step={0.1}
      value={clampPlaybackTime(position, duration)} onChange={(event) => seek(Number(event.target.value))}
      className="block h-8 w-full" />
    <div className="flex items-center justify-between gap-3 text-xs tabular-nums text-muted-foreground"><span>{formatPodcastTime(position)}</span><span>{formatPodcastTime(duration)}</span></div>
    {valid.length ? <details className="text-xs"><summary className="min-h-9 cursor-pointer py-2">Chapters ({valid.length})</summary>
      <ol className="max-h-36 overflow-y-auto">{valid.map((chapter, index) => <li key={`${chapter.startSeconds}:${index}`}><button type="button"
        onClick={() => seek(chapter.startSeconds)} className="flex min-h-11 w-full items-center gap-3 rounded px-2 text-left hover:bg-accent">
        <span className="shrink-0 tabular-nums text-muted-foreground">{formatPodcastTime(chapter.startSeconds)}</span><span className="break-words">{chapter.title}</span>
      </button></li>)}</ol>
    </details> : null}
  </div>;
}
