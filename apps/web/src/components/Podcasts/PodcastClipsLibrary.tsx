"use client";

import { usePodcastClips } from "@/hooks/usePodcastClips";
import { usePodcastViewer } from "@/hooks/usePodcastViewer";
import { PodcastClipCard } from "./PodcastClipCard";

export function PodcastClipsLibrary() {
  const viewer = usePodcastViewer();
  const { clips, loading, error, refresh } = usePodcastClips();
  return <section aria-label="Your Podcast Clips" className="space-y-4">
    <h2 className="text-lg font-semibold">Clips</h2>
    {error ? <div role="alert" className="flex flex-wrap items-center gap-3 text-sm text-destructive">
      <p>{error}</p><button type="button" className="rounded-lg border px-3 py-2" onClick={() => void refresh()}>Retry</button>
    </div> : null}
    {!viewer ? <p className="text-sm text-muted-foreground">Sign In to View Your Clips</p> : loading ? <p role="status" className="text-sm text-muted-foreground">Loading Clips…</p> : !clips.length && !error ? <p className="text-sm text-muted-foreground">No Clips Yet. Choose Clip From an Episode to Get Started.</p> : null}
    <ul className="space-y-4">{clips.map(clip => <li key={`${viewer}:${clip.id}`}><PodcastClipCard clip={clip} onChanged={() => void refresh()} /></li>)}</ul>
  </section>;
}
