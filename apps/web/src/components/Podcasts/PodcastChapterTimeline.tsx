"use client";
import { useState } from "react";
import type { PodcastChapter } from "@/lib/podcasts/client";
import { formatPodcastTime, orderedPodcastChapters } from "@/lib/podcasts/playback";
import { PodcastArtwork } from "./PodcastArtwork";
import { PodcastSeekBar } from "./PodcastSeekBar";

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
    {valid.length && duration > 0 ? <div aria-label="Chapter Markers" className="relative mx-3 h-3 pointer-coarse:h-11">
      {duration > 0 ? valid.map((chapter, index) => <button key={`${chapter.startSeconds}:${index}`} type="button"
        aria-label={`Seek to Chapter: ${chapter.title}, ${formatPodcastTime(chapter.startSeconds)}`}
        aria-describedby={preview === index ? "podcast-chapter-preview" : undefined}
        onMouseEnter={() => setPreview(index)} onMouseLeave={(event) => { if (!event.currentTarget.matches(":focus")) setPreview(null); }}
        onFocus={() => setPreview(index)} onBlur={() => setPreview(null)}
        onClick={() => { setPreview(index); seek(chapter.startSeconds); }}
        style={{ left: `${Math.min(100, chapter.startSeconds / duration * 100)}%` }}
        className="absolute top-1/2 flex h-6 w-6 pointer-coarse:h-11 pointer-coarse:w-11 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded focus-visible:outline-2 focus-visible:outline-ring">
        <span className="h-1.5 w-0.5 bg-primary" aria-hidden="true" />
      </button>) : null}
      {hovered ? <div id="podcast-chapter-preview" role="tooltip" className="absolute bottom-full left-1/2 z-10 mb-1 flex w-60 max-w-full -translate-x-1/2 items-center gap-3 rounded-lg border bg-background p-3 shadow-lg">
        {hovered.artworkUrl || artworkSources.some(Boolean) ? <div className="size-12 shrink-0"><PodcastArtwork key={hovered.artworkUrl} src={hovered.artworkUrl ?? artworkSources.find(Boolean)} fallbackSources={artworkSources} alt={`Chapter Artwork: ${hovered.title}`} size={48} /></div> : null}
        <div className="min-w-0"><p className="break-words text-sm font-medium">{hovered.title}</p><p className="text-xs text-muted-foreground">{formatPodcastTime(hovered.startSeconds)}</p></div>
      </div> : null}
    </div> : null}
    <PodcastSeekBar position={position} duration={duration} seek={seek} />
    <div className="flex items-center justify-between gap-3 text-xs tabular-nums text-muted-foreground"><span>{formatPodcastTime(position)}</span>
    {valid.length ? <details className="relative text-xs"><summary className="min-h-6 cursor-pointer py-1 pointer-coarse:min-h-11">Chapters ({valid.length})</summary>
      <ol className="absolute bottom-full left-1/2 z-10 mb-2 max-h-48 w-72 max-w-[calc(100vw-2rem)] -translate-x-1/2 overflow-y-auto rounded-lg border bg-background p-2 shadow-lg">{valid.map((chapter, index) => <li key={`${chapter.startSeconds}:${index}`}><button type="button"
        onClick={() => seek(chapter.startSeconds)} className="flex min-h-11 w-full items-center gap-3 rounded px-2 text-left hover:bg-accent">
        <span className="shrink-0 tabular-nums text-muted-foreground">{formatPodcastTime(chapter.startSeconds)}</span><span className="break-words">{chapter.title}</span>
      </button></li>)}</ol>
    </details> : null}
    <span>{formatPodcastTime(duration)}</span></div>
  </div>;
}
