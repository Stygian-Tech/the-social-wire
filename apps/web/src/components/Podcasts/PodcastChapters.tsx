"use client";

import type { PodcastChapter } from "@/lib/podcasts/client";
import { activePodcastChapter, formatPodcastTime } from "@/lib/podcasts/playback";
import { PodcastArtwork } from "./PodcastArtwork";

export function PodcastChapters({ chapters = [], artworkSources = [], position, onSeek }: { chapters?: PodcastChapter[]; artworkSources?: (string | undefined)[]; position: number; onSeek: (seconds: number) => void }) {
  const ordered = chapters.filter(chapter => Number.isFinite(chapter.startSeconds) && chapter.startSeconds >= 0).toSorted((a, b) => a.startSeconds - b.startSeconds);
  if (!ordered.length) return null;
  const active = activePodcastChapter(ordered, position);
  return <section aria-label="Episode Chapters" className="space-y-2">
    <h3 className="font-medium">Chapters</h3>
    <ol className="space-y-1">{ordered.map((chapter, index) => <li key={`${chapter.startSeconds}-${index}`}>
      <button type="button" aria-current={chapter === active ? "true" : undefined}
        onClick={() => onSeek(chapter.startSeconds)} className={`flex min-h-11 w-full items-center gap-3 rounded-lg p-2 text-left text-sm ${chapter === active ? "bg-accent" : "hover:bg-accent/60"}`}>
        <PodcastArtwork src={chapter.artworkUrl ?? artworkSources.find(Boolean)} fallbackSources={artworkSources} alt="" size={40} className="size-10" />
        <span className="min-w-0 flex-1 break-words">{chapter.title}</span><span className="tabular-nums text-muted-foreground">{formatPodcastTime(chapter.startSeconds)}</span>
      </button>
    </li>)}</ol>
  </section>;
}
