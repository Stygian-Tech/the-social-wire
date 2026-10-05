"use client";
import { useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import {
  podcastRequest,
  publishPodcastClip,
  unpublishPodcastClip,
  type PodcastClip,
  type PodcastEpisode,
} from "@/lib/podcasts/client";
import { validateClipBounds, formatPodcastTime } from "@/lib/podcasts/playback";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
const button = "min-h-11 rounded border px-3 text-sm hover:bg-accent";
export function PodcastClips({ episode }: { episode: PodcastEpisode }) {
  const { session, getOAuthSession } = useAuth();
  const player = usePodcastPlayer();
  const [start, setStart] = useState(0);
  const [end, setEnd] = useState(30);
  const [title, setTitle] = useState(episode.title);
  const [includeCaptions, setIncludeCaptions] = useState(true);
  const [clips, setClips] = useState<PodcastClip[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [preview, setPreview] = useState(false);
  useEffect(() => {
    if (preview && player.position >= end) {
      if (player.playing) player.toggle();
      queueMicrotask(() => setPreview(false));
    }
  }, [preview, player, end]);
  useEffect(() => {
    const oauth = getOAuthSession();
    if (!oauth) return;
    let cancelled = false;
    const refresh = () =>
      podcastRequest<{ clips: PodcastClip[] }>(oauth, "clips")
        .then((page) => {
          if (!cancelled)
            setClips(
              page.clips.filter((clip) => clip.episodeId === episode.id),
            );
        })
        .catch((reason) => {
          if (!cancelled) setError(String(reason));
        });
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [getOAuthSession, episode.id]);
  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  }
  async function exportAsset(clip: PodcastClip, format: "audio" | "video") {
    const oauth = getOAuthSession();
    if (!oauth) throw new Error("Sign in to export a draft");
    const response = await gatewayFetch(
      oauth,
      `/v1/podcasts/assets?clipId=${encodeURIComponent(clip.id)}&format=${format}`,
    );
    if (!response.ok) throw new Error(`Export failed (${response.status})`);
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `${clip.title.replace(/[^a-z0-9 -]/gi, "").slice(0, 80) || "Podcast Clip"}.${format === "audio" ? "m4a" : "mp4"}`;
    anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
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
      <div className="flex flex-wrap gap-3">
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
        <button className={button} onClick={() => setStart(player.position)}>
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
        <button className={button} onClick={() => setEnd(player.position)}>
          End Here
        </button>
        <input
          aria-label="Clip Title"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          className="min-h-11 flex-1 rounded border bg-background px-3"
        />
      </div>
      <label className="flex min-h-11 items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={includeCaptions}
          onChange={(event) => setIncludeCaptions(event.target.checked)}
        />
        Include Captions
        <span className="text-muted-foreground">
          When a Publisher Transcript Is Available
        </span>
      </label>
      <div className="flex gap-2">
        <button
          className={button}
          disabled={!valid || busy}
          onClick={() => {
            player.seek(start);
            if (!player.playing) player.toggle();
            setPreview(true);
          }}
        >
          Preview Clip
        </button>
        <button
          className={button}
          disabled={!valid || busy}
          onClick={() =>
            void run(async () => {
              const oauth = getOAuthSession();
              if (!oauth) throw new Error("Sign in to create clips");
              await podcastRequest(oauth, "clips", "POST", {
                episodeId: episode.id,
                startSeconds: start,
                endSeconds: end,
                title,
                includeCaptions,
              });
              const page = await podcastRequest<{ clips: PodcastClip[] }>(
                oauth,
                "clips",
              );
              setClips(
                page.clips.filter((clip) => clip.episodeId === episode.id),
              );
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
      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
      <ul className="space-y-3">
        {clips.map((clip) => (
          <li key={clip.id} className="rounded border p-3">
            <p className="font-medium">{clip.title}</p>
            <p className="text-sm text-muted-foreground">
              {formatPodcastTime(clip.startSeconds)}–
              {formatPodcastTime(clip.endSeconds)} · {clip.status}
            </p>
            {clip.error ? (
              <p className="text-sm text-destructive">{clip.error}</p>
            ) : null}
            <div className="mt-2 flex flex-wrap gap-2">
              {clip.status === "failed" ? (
                <button
                  className={button}
                  disabled={busy}
                  onClick={() =>
                    void run(async () => {
                      const oauth = getOAuthSession();
                      if (!oauth) throw new Error("Sign In to Retry Exports");
                      const job = clip.jobId
                        ? { id: clip.jobId }
                        : await podcastRequest<{ id: string }>(
                            oauth,
                            `jobs?clipId=${encodeURIComponent(clip.id)}`,
                          );
                      await podcastRequest(oauth, "jobs", "POST", {
                        jobId: job.id,
                      });
                      setClips((items) =>
                        items.map((item) =>
                          item.id === clip.id
                            ? { ...item, status: "queued" }
                            : item,
                        ),
                      );
                    })
                  }
                >
                  Retry Exports
                </button>
              ) : null}
              {clip.audioUrl ? (
                <button
                  className={button}
                  onClick={() => void run(() => exportAsset(clip, "audio"))}
                >
                  Audio Export
                </button>
              ) : null}
              {clip.videoUrl ? (
                <button
                  className={button}
                  onClick={() => void run(() => exportAsset(clip, "video"))}
                >
                  Audiogram Export
                </button>
              ) : null}
              {!clip.publishedUri ? (
                <button
                  className={button}
                  disabled={busy || !clip.audioUrl || !clip.videoUrl}
                  onClick={() =>
                    void run(async () => {
                      const oauth = getOAuthSession();
                      if (!oauth || !session) return;
                      const uri = await publishPodcastClip(
                        oauth,
                        session.did,
                        clip,
                        episode,
                      );
                      setClips((items) =>
                        items.map((item) =>
                          item.id === clip.id
                            ? { ...item, publishedUri: uri }
                            : item,
                        ),
                      );
                    })
                  }
                >
                  Publish
                </button>
              ) : (
                <>
                  <a
                    className={button}
                    href={`/podcast-clips/${encodeURIComponent(clip.id)}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Public Clip
                  </a>
                  <button
                    className={button}
                    onClick={() =>
                      void run(async () => {
                        const url = `${location.origin}/podcast-clips/${encodeURIComponent(clip.id)}`;
                        if (navigator.share)
                          await navigator.share({ title: clip.title, url });
                        else await navigator.clipboard.writeText(url);
                      })
                    }
                  >
                    Share
                  </button>
                  <button
                    className={button}
                    onClick={() =>
                      void navigator.clipboard.writeText(
                        `<iframe src="${location.origin}/podcast-clips/${encodeURIComponent(clip.id)}/embed" title="Podcast Clip" width="480" height="200" loading="lazy" allow="autoplay"></iframe>`,
                      )
                    }
                  >
                    Copy Embed
                  </button>
                </>
              )}
              <button
                className={button}
                disabled={busy}
                onClick={() => {
                  if (
                    window.confirm(
                      "Delete This Clip? This removes its public record and hosted exports.",
                    )
                  )
                    void run(async () => {
                      const oauth = getOAuthSession();
                      if (!oauth || !session) return;
                      await unpublishPodcastClip(oauth, session.did, clip);
                      setClips((items) =>
                        items.filter((item) => item.id !== clip.id),
                      );
                    });
                }}
              >
                Delete Clip
              </button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
