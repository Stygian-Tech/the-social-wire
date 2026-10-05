"use client";

import { PodcastArtwork } from "./PodcastArtwork";
import type { PodcastShow } from "@/lib/podcasts/client";

const button = "min-h-11 rounded border px-3 text-sm hover:bg-accent disabled:opacity-50";

export function PodcastLibrarySearch({ scope, query, label, valid, loading, error, shows, onQuery, onRetry, onShow }: {
  scope: "library" | "discover";
  query: string;
  label: string;
  valid: boolean;
  loading: boolean;
  error: string | null;
  shows: PodcastShow[];
  onQuery: (query: string) => void;
  onRetry: () => void;
  onShow: (show: PodcastShow) => void;
}) {
  const searching = !!query.trim();
  return (
    <div className="space-y-2">
      {scope === "discover" ? <p className="text-xs text-muted-foreground">Discover Public Podcasts with <a className="underline" href="https://podcastindex.org" target="_blank" rel="noreferrer">Podcast Index</a>. Only searches entered here are sent to the directory.</p> : null}
      <label htmlFor="podcast-library-search" className="block text-sm font-medium">{label}</label>
      <div className="flex min-w-0 gap-2">
        <input
          id="podcast-library-search"
          type="search"
          maxLength={200}
          value={query}
          onChange={event => onQuery(event.target.value)}
          placeholder={scope === "discover" ? "Find a Public Podcast" : "Shows, Episodes, or Hosts"}
          className="min-h-11 w-full min-w-0 rounded-lg border bg-background px-3 text-sm"
        />
        {searching ? <button type="button" className={button} onClick={() => onQuery("")}>Clear Search</button> : null}
      </div>
      {searching && !valid ? <p className="text-sm text-muted-foreground">Enter at Least 2 Characters</p> : null}
      {searching && loading ? <p role="status" className="text-sm text-muted-foreground">{scope === "discover" ? "Searching Podcast Index…" : "Searching Your Library…"}</p> : null}
      {searching && error ? (
        <div role="alert" className="text-sm text-destructive">
          <p>{error}</p>
          <button type="button" className={button} onClick={onRetry}>Retry Search</button>
        </div>
      ) : null}
      {searching && shows.length ? (
        <section aria-label="Matching Shows" className="space-y-2">
          <h2 className="text-lg font-semibold">Matching Shows</h2>
          <ul className="space-y-2">
            {shows.map(show => (
              <li key={show.id}>
                <button type="button" className={`${button} flex w-full items-center gap-3 py-2 text-left`} onClick={() => onShow(show)}>
                  <PodcastArtwork src={show.artworkUrl} alt="" size={40} className="size-10" />
                  <span>{show.title}{show.visibility === "private" ? <span className="block text-xs text-muted-foreground">Private Feed</span> : null}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </div>
  );
}
