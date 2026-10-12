"use client";
import { useEffect, useRef, useState } from "react";
import { usePodcastViewer } from "@/hooks/usePodcastViewer";
import { usePodcastClipAccount } from "@/hooks/usePodcastClipAccount";
import { usePodcastClips } from "@/hooks/usePodcastClips";
import { podcastRequest, type PodcastEpisode } from "@/lib/podcasts/client";
import { validateClipBounds } from "@/lib/podcasts/playback";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
import { PodcastClipCard } from "./PodcastClipCard";
import { podcastClipButton } from "./podcastClipStyles";

export function PodcastClips({ episode }: { episode: PodcastEpisode }) {
  const viewer = usePodcastViewer();
  return <PodcastViewerClips key={`${viewer ?? "signed-out"}:${episode.id}`} episode={episode} />;
}
function PodcastViewerClips({ episode }: { episode: PodcastEpisode }) {
  const { requireSession, assertCurrentAccount } = usePodcastClipAccount();
  const { clips, error: pollError, refresh } = usePodcastClips(episode.id);
  const player = usePodcastPlayer();
  const [start, setStart] = useState(0);
  const [end, setEnd] = useState(30);
  const [title, setTitle] = useState(episode.title);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [preview, setPreview] = useState(false);
  const running = useRef(false);
  useEffect(() => {
    if (preview && player.position >= end) {
      if (player.playing) player.toggle();
      queueMicrotask(() => setPreview(false));
    }
  }, [preview, player, end]);
  async function run(action: () => Promise<void>) {
    if (running.current) return;
    running.current = true; setBusy(true); setError(null);
    try { await action(); }
    catch (reason) { setError(reason instanceof Error && reason.message.startsWith("Account Is Loading") ? "Account Is Loading. Please Retry." : "Clip Action Failed. Please Retry."); }
    finally { running.current = false; setBusy(false); }
  }
  const valid = validateClipBounds(
    start,
    end,
    episode.durationSeconds ?? player.duration,
  );
  return (
    <section aria-label="Podcast Clips" className="space-y-3">
      <h3 className="font-semibold">Clip for Social Media</h3>
      <p className="text-sm text-muted-foreground">
        Select up to 10 minutes. Drafts stay private until you publish. Exports
        retain the original timing and pauses.
      </p>
      <div className="flex flex-wrap items-center gap-3">
        <label className="text-sm">
          Start (Seconds)
          <input
            type="number"
            min={0}
            step={0.1}
            value={start}
            onChange={(event) => setStart(Number(event.target.value))}
            className="ml-2 w-24 rounded border bg-background p-2"
          />
        </label>
        <button className={podcastClipButton} onClick={() => setStart(player.position)}>
          Start Here
        </button>
        <label className="text-sm">
          End (Seconds)
          <input
            type="number"
            min={start}
            step={0.1}
            value={end}
            onChange={(event) => setEnd(Number(event.target.value))}
            className="ml-2 w-24 rounded border bg-background p-2"
          />
        </label>
        <button className={podcastClipButton} onClick={() => setEnd(player.position)}>
          End Here
        </button>
        <input
          aria-label="Clip Title"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          className="min-h-11 flex-1 rounded border bg-background px-3"
        />
      </div>
      <div className="flex gap-2">
        <button
          className={podcastClipButton}
          disabled={!valid || busy}
          onClick={() => {
            player.seek(start);
            if (!player.playing) player.toggle();
            setPreview(true);
          }}
        >
          Preview Audio Range
        </button>
        <button
          className={podcastClipButton}
          disabled={!valid || busy}
          onClick={() =>
            void run(async () => {
              const oauth = requireSession();
              if (!oauth) throw new Error("Sign in to create clips");
              assertCurrentAccount();
              await podcastRequest(oauth, "clips", "POST", {
                episodeId: episode.id,
                startSeconds: start,
                endSeconds: end,
                title,
                includeCaptions: false,
              });
              assertCurrentAccount();
              await refresh();
            })
          }
        >
          Prepare Exports
        </button>
      </div>
      {!valid ? (
        <p className="text-sm text-muted-foreground">
          Choose a valid range within the episode, up to 10 minutes.
        </p>
      ) : null}
      {error || pollError ? (
        <p role="alert" className="text-sm text-destructive">
          {error ?? pollError}
        </p>
      ) : null}
      <ul className="space-y-3">
        {clips.map(clip => <li key={clip.id}><PodcastClipCard clip={clip} episode={episode} onChanged={refresh} /></li>)}
      </ul>
    </section>
  );
}
