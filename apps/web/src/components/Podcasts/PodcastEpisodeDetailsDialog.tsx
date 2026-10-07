"use client";

import { useMemo, useState } from "react";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import type { PodcastEpisode } from "@/lib/podcasts/client";
import { formatPodcastTime } from "@/lib/podcasts/playback";
import { sanitizeHTMLWithLinks } from "@/lib/sanitize";
import { PodcastArtwork } from "./PodcastArtwork";

export function PodcastEpisodeDetailsDialog({ episode, showName }: { episode: PodcastEpisode; showName?: string }) {
  const [open, setOpen] = useState(false);
  const notes = useMemo(() => open ? sanitizeHTMLWithLinks(episode.description ?? "") : "", [open, episode.description]);
  return <Dialog open={open} onOpenChange={setOpen}>
    <DialogTrigger aria-label={`Show Notes: ${episode.title}`} className="block w-full min-w-0 rounded text-left hover:bg-accent/30 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring">
      {showName ? <span className="mb-2 block line-clamp-2 break-words text-xs font-medium text-muted-foreground">{showName}</span> : null}
      <span className="flex items-center gap-3">
        <PodcastArtwork src={episode.artworkUrl ?? episode.showArtworkUrl} alt="" size={64} className="size-16" />
        <span role="heading" aria-level={3} className="min-w-0 break-words font-semibold">{episode.title}</span>
      </span>
      <span className="mt-1 block text-xs text-muted-foreground">
        {episode.publishedAt ? new Date(episode.publishedAt).toLocaleDateString() : ""}{" "}
        {episode.durationSeconds ? `· ${formatPodcastTime(episode.durationSeconds)}` : ""}
      </span>
      {episode.description ? <span className="mt-2 block line-clamp-3 text-sm text-muted-foreground">{episode.description.replace(/<[^>]*>/g, " ")}</span> : null}
    </DialogTrigger>
    <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-2xl" showCloseButton={false}>
      <DialogHeader>
        <DialogTitle>{episode.title}</DialogTitle>
        <DialogDescription>{showName ? `${showName} · Show Notes` : "Episode Show Notes"}</DialogDescription>
      </DialogHeader>
      <div className="min-h-0 overflow-y-auto overscroll-contain break-words pr-1 text-sm [&_p]:mb-3 [&_a]:underline [&_ul]:list-inside [&_ul]:list-disc [&_ol]:list-inside [&_ol]:list-decimal [&_img]:max-w-full" tabIndex={0} aria-label="Episode Show Notes">
        {notes ? <div dangerouslySetInnerHTML={{ __html: notes }} /> : <p className="text-muted-foreground">No Show Notes Are Available for This Episode</p>}
      </div>
      <DialogFooter><DialogClose className="min-h-8 rounded border px-2 text-xs hover:bg-accent pointer-coarse:min-h-11">Close</DialogClose></DialogFooter>
    </DialogContent>
  </Dialog>;
}
