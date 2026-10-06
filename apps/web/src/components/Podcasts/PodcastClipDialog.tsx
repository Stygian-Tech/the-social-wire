"use client";

import { useEffect, useState } from "react";
import { Scissors } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { usePodcastViewer } from "@/hooks/usePodcastViewer";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { podcastRequest, type PodcastEpisode, type PodcastTranscript } from "@/lib/podcasts/client";
import { getPodcastDownload } from "@/lib/podcasts/offline";
import type { PlayerContext } from "./PodcastPlayerProvider";
import { PodcastChapters } from "./PodcastChapters";
import { PodcastClips } from "./PodcastClips";
import { PodcastTranscripts } from "./PodcastTranscripts";

export function PodcastClipDialog({ player, episode }: { player: PlayerContext; episode: PodcastEpisode }) {
  const { getOAuthSession } = useAuth();
  const viewer = usePodcastViewer();
  const [open, setOpen] = useState(false);
  const [transcripts, setTranscripts] = useState<PodcastTranscript[]>(episode.transcripts);

  useEffect(() => {
    if (!open || !viewer) return;
    const controller = new AbortController();
    const oauth = getOAuthSession();
    void (oauth && navigator.onLine
      ? podcastRequest<{ transcripts: PodcastTranscript[] }>(oauth, `transcript?episodeId=${encodeURIComponent(episode.id)}`, "GET", undefined, controller.signal)
      : Promise.reject(new Error("Offline")))
      .then(result => { if (!controller.signal.aborted) setTranscripts(result.transcripts); })
      .catch(async () => {
        if (controller.signal.aborted) return;
        const local = await getPodcastDownload(viewer, episode.id).catch(() => undefined);
        if (!controller.signal.aborted) setTranscripts(local?.transcripts ?? (local?.transcript ? [local.transcript] : episode.transcripts));
      });
    return () => controller.abort();
  }, [open, episode, viewer, getOAuthSession]);

  return <Dialog open={open} onOpenChange={nextOpen => {
    if (nextOpen) setTranscripts(episode.transcripts);
    setOpen(nextOpen);
  }}>
    <DialogTrigger className="inline-flex min-h-8 items-center gap-1.5 rounded border px-2 text-xs hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring pointer-coarse:min-h-11">
      <Scissors aria-hidden="true" className="size-3.5" />Clip
    </DialogTrigger>
    <DialogContent className="max-h-[calc(100dvh-3rem)] overflow-y-auto sm:max-w-2xl">
      <DialogHeader className="pr-8">
        <DialogTitle>Clip for Social Media</DialogTitle>
        <DialogDescription>Now Playing: {episode.title}</DialogDescription>
      </DialogHeader>
      {open ? <div className="min-w-0 space-y-5">
        <PodcastChapters chapters={episode.chapters} position={player.position} onSeek={player.seek} />
        <PodcastTranscripts transcripts={transcripts} />
        {episode.visibility !== "private" ? <PodcastClips episode={episode} /> : <p className="text-sm text-muted-foreground">Clips Are Unavailable for Private Feeds</p>}
      </div> : null}
    </DialogContent>
  </Dialog>;
}
