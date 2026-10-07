"use client";

import { useMemo, useState } from "react";
import { CheckCircle, Circle } from "lucide-react";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import type { PodcastEpisode } from "@/lib/podcasts/client";
import { formatPodcastTime } from "@/lib/podcasts/playback";
import { sanitizeHTMLWithLinks } from "@/lib/sanitize";
import { linkPodcastTimecodes, podcastNotesExcerpt } from "@/lib/podcasts/showNotes";
import { PodcastArtwork } from "./PodcastArtwork";

export function PodcastEpisodeDetailsDialog({ episode, showName, played, onTimecode }: { episode: PodcastEpisode; showName?: string; played?: boolean; onTimecode?: (seconds: number) => void }) {
  const [open, setOpen] = useState(false);
  const notes = useMemo(() => open ? linkPodcastTimecodes(sanitizeHTMLWithLinks(episode.description ?? ""), episode.durationSeconds) : "", [open, episode.description, episode.durationSeconds]);
  const excerpt = useMemo(() => podcastNotesExcerpt(episode.description ?? ""), [episode.description]);
  return <Dialog open={open} onOpenChange={setOpen}>
    <DialogTrigger aria-label={`Show Notes: ${episode.title}`} className="block w-full min-w-0 rounded text-left hover:bg-accent/30 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring">
      <span className="mb-2 flex items-start justify-between gap-3 text-xs text-muted-foreground">
        {showName ? <span className="min-w-0 flex-1 line-clamp-2 break-words font-medium">{showName}</span> : <span />}
        {played !== undefined ? <span className="inline-flex shrink-0 items-center gap-1.5">
          {played ? <CheckCircle aria-hidden="true" className="size-3.5" /> : <Circle aria-hidden="true" className="size-3.5" />}
          {played ? "Played" : "Unplayed"}
        </span> : null}
      </span>
      <span className="flex items-center gap-3">
        <PodcastArtwork src={episode.artworkUrl} fallbackSources={[episode.showArtworkUrl]} alt="" size={64} className={`size-16 ${played ? "opacity-60 grayscale" : ""}`} />
        <span role="heading" aria-level={3} className={`min-w-0 break-words font-semibold ${played ? "text-muted-foreground" : ""}`}>{episode.title}</span>
      </span>
      <span className="mt-1 block text-xs text-muted-foreground">
        {episode.publishedAt ? new Date(episode.publishedAt).toLocaleDateString() : ""}{" "}
        {episode.durationSeconds ? `· ${formatPodcastTime(episode.durationSeconds)}` : ""}
      </span>
      {excerpt ? <span className="mt-2 line-clamp-3 max-h-15 overflow-hidden text-sm leading-5 text-muted-foreground">{excerpt}</span> : null}
    </DialogTrigger>
    <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-2xl" showCloseButton={false}>
      <DialogHeader>
        <div className="flex min-w-0 items-start gap-3">
          <PodcastArtwork src={episode.artworkUrl} fallbackSources={[episode.showArtworkUrl]} alt={`${episode.title} Artwork`} size={64} className="size-16" />
          <div className="min-w-0 space-y-1 text-left">
            <DialogTitle className="break-words">{episode.title}</DialogTitle>
            <DialogDescription className="break-words">{showName ? `${showName} · Show Notes` : "Episode Show Notes"}</DialogDescription>
          </div>
        </div>
      </DialogHeader>
      <div className="min-h-0 overflow-y-auto overscroll-contain break-words pr-1 text-sm [&_p]:mb-3 [&_a]:underline [&_ul]:list-inside [&_ul]:list-disc [&_ol]:list-inside [&_ol]:list-decimal [&_img]:max-w-full" tabIndex={0} aria-label="Episode Show Notes" onClick={event => {
        const target = event.target instanceof Element ? event.target.closest<HTMLButtonElement>("button[data-podcast-timecode]") : null;
        if (target && event.currentTarget.contains(target)) onTimecode?.(Number(target.dataset.podcastTimecode));
      }}>
        {notes ? <div dangerouslySetInnerHTML={{ __html: notes }} /> : <p className="text-muted-foreground">No Show Notes Are Available for This Episode</p>}
      </div>
      <DialogFooter><DialogClose className="min-h-8 rounded border px-2 text-xs hover:bg-accent pointer-coarse:min-h-11">Close</DialogClose></DialogFooter>
    </DialogContent>
  </Dialog>;
}
