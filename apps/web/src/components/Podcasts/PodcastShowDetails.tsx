"use client";

import type { PodcastShow } from "@/lib/podcasts/client";
import { PodcastArtwork } from "./PodcastArtwork";

export function PodcastShowDetails({ show }: { show: PodcastShow }) {
  return <div className="flex min-w-0 flex-col gap-4 sm:flex-row">
    <PodcastArtwork src={show.artworkUrl} alt={`${show.title} Artwork`} size={112} className="size-28" />
    <div className="min-w-0 flex-1 space-y-3">
      <h2 className="break-words text-xl font-semibold">{show.title}</h2>
      {show.description ? <p className="line-clamp-3 text-sm text-muted-foreground">{show.description.replace(/<[^>]*>/g, " ")}</p> : null}
      {show.hosts?.length ? <section aria-label="Podcast Hosts">
        <h3 className="mb-2 text-xs font-medium text-muted-foreground">Hosts</h3>
        <ul className="flex flex-wrap gap-4">{show.hosts.map((host, index) => <li key={`${host.name}-${index}`} className="flex items-center gap-2">
          {host.imageUrl ? <PodcastArtwork src={host.imageUrl} alt={`${host.name} Photo`} size={40} className="size-10 rounded-full" /> : null}
          <span className="break-words text-sm">{host.name}</span>
        </li>)}</ul>
      </section> : null}
    </div>
  </div>;
}
