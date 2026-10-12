"use client";

import { Check, Plus } from "lucide-react";
import type { PodcastDirectoryCandidate } from "@/hooks/usePodcastLibrarySearch";
import { PodcastArtwork } from "./PodcastArtwork";

export function PodcastDirectoryResults({ candidates, directoryLimit, query, loading, failed, busy, onPreview, onSubscribe, isSubscribed }: {
  candidates: PodcastDirectoryCandidate[];
  directoryLimit: number;
  query: string;
  loading: boolean;
  failed: boolean;
  busy: boolean;
  isSubscribed: (candidate: PodcastDirectoryCandidate) => boolean;
  onSubscribe: (candidate: PodcastDirectoryCandidate) => void;
  onPreview: (candidate: PodcastDirectoryCandidate) => void;
}) {
  return (
    <section aria-label="Podcast Index Results" className="space-y-3">
      {!query.trim() ? <p className="text-sm text-muted-foreground">Find a public podcast to preview or subscribe.</p> : null}
      {query.trim().length >= 2 && !loading && !failed && !candidates.length ? <p className="text-sm text-muted-foreground">No Podcasts Found</p> : null}
      {candidates.length ? <p className="text-xs text-muted-foreground">Up to {directoryLimit} Results from Podcast Index</p> : null}
      <ul className="space-y-3">
        {candidates.map(candidate => (
          <li key={`${candidate.provider}:${candidate.id}`} className="rounded-xl border p-4">
            <div className="flex items-center gap-3">
              <PodcastArtwork src={candidate.artworkUrl} alt="" size={64} className="size-16" />
              <h2 className="min-w-0 break-words font-semibold">{candidate.title}</h2>
            </div>
            {candidate.description ? <p className="mt-2 line-clamp-3 text-sm text-muted-foreground">{candidate.description.replace(/<[^>]*>/g, " ")}</p> : null}
            <div className="mt-3 flex flex-wrap gap-2">
              <button type="button" disabled={busy} className="min-h-11 rounded border px-3 text-sm hover:bg-accent disabled:opacity-50" onClick={() => onPreview(candidate)}>Preview Podcast</button>
              <button type="button" disabled={busy || isSubscribed(candidate)} className="inline-flex min-h-11 items-center gap-1.5 rounded border px-3 text-sm hover:bg-accent disabled:opacity-50" onClick={() => onSubscribe(candidate)}>
                {isSubscribed(candidate) ? <Check aria-hidden="true" className="size-4" /> : <Plus aria-hidden="true" className="size-4" />}
                {isSubscribed(candidate) ? "Subscribed" : "Subscribe"}
              </button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
