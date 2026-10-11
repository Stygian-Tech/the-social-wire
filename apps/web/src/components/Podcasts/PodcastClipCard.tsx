"use client";
import { useEffect, useRef, useState } from "react";
import { usePodcastClipAccount } from "@/hooks/usePodcastClipAccount";
import { fetchPodcastClipAsset } from "@/lib/podcasts/clipAsset";
import { podcastRequest, publishPodcastClip, unpublishPodcastClip, type PodcastClip, type PodcastEpisode } from "@/lib/podcasts/client";
import { publishBlueskyPodcastClip, PodcastClipAlreadyPublishedError } from "@/lib/podcasts/blueskyClipPublisher";
import { formatPodcastTime } from "@/lib/podcasts/playback";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
import { PodcastClipPreview } from "./PodcastClipPreview";
import { PodcastClipComposer } from "./PodcastClipComposer";
import { podcastClipButton as button } from "./podcastClipStyles";

export function PodcastClipCard(props: { clip: PodcastClip; episode?: PodcastEpisode; onChanged?: () => void | Promise<void> }) {
  const { viewer } = usePodcastClipAccount();
  return viewer ? <ViewerClipCard key={`${viewer}:${props.clip.id}`} {...props} /> : null;
}
function ViewerClipCard({ clip, episode, onChanged }: { clip: PodcastClip; episode?: PodcastEpisode; onChanged?: () => void | Promise<void> }) {
  const { viewer, requireSession, assertCurrentAccount } = usePodcastClipAccount();
  const player = usePodcastPlayer();
  const [media, setMedia] = useState<{ blob: Blob; url: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState<string | null>(null);
  const [composer, setComposer] = useState(false);
  const [composerVersion, setComposerVersion] = useState(0);
  const [postUri, setPostUri] = useState<string | null>(null);
  const controller = useRef<AbortController | null>(null);
  const objectUrls = useRef(new Set<string>());
  const exportTimers = useRef(new Set<ReturnType<typeof setTimeout>>());
  const running = useRef(false);
  useEffect(() => () => {
    controller.current?.abort();
    for (const url of objectUrls.current) URL.revokeObjectURL(url);
    objectUrls.current.clear();
    for (const timer of exportTimers.current) clearTimeout(timer);
  }, []);
  useEffect(() => {
    const abort = (event: Event) => {
      if (event.type === "storage" && (event as StorageEvent).key !== "@@atproto/oauth-client-browser(sub)") return;
      controller.current?.abort();
      for (const url of objectUrls.current) URL.revokeObjectURL(url);
      objectUrls.current.clear(); setMedia(null); setComposer(false); setBusy(false); setProgress(null);
    };
    window.addEventListener("storage", abort); window.addEventListener("the-social-wire.oauth-viewer-changed", abort);
    return () => { window.removeEventListener("storage", abort); window.removeEventListener("the-social-wire.oauth-viewer-changed", abort); };
  }, []);
  const check = () => { controller.current?.signal.throwIfAborted(); assertCurrentAccount(); };
  async function run(action: (signal: AbortSignal) => Promise<void>) {
    if (running.current) return;
    running.current = true;
    const operation = new AbortController();
    controller.current = operation;
    setBusy(true); setError(null);
    try { check(); await action(operation.signal); check(); }
    catch (reason) {
    if (!operation.signal.aborted) {
        try { assertCurrentAccount();
          if (reason instanceof PodcastClipAlreadyPublishedError) { setPostUri(reason.uri); setComposer(false); }
          setError(reason instanceof Error ? reason.message : "Clip Action Failed. Please Retry."); } catch { /* Discard stale account results. */ }
      }
    } finally {
      running.current = false;
      if (!operation.signal.aborted) { setBusy(false); setProgress(null); }
    }
  }
  const pauseMainAudio = () => { if (player.playing) player.toggle(); };
  async function loadVideo(signal: AbortSignal) {
    check();
    if (media) return media;
    const blob = await fetchPodcastClipAsset({ session: requireSession(), clipId: clip.id, format: "video", signal, assertCurrentAccount });
    check();
    const url = URL.createObjectURL(blob);
    objectUrls.current.add(url);
    const prepared = { blob, url };
    setMedia(prepared);
    return prepared;
  }
  const ready = clip.status === "complete" && Boolean(clip.videoUrl);
  return <article aria-label={`Clip: ${clip.title}`} className="space-y-3 rounded-2xl border bg-card p-4">
    <div><h3 className="font-medium">{clip.title}</h3><p className="text-sm text-muted-foreground">{formatPodcastTime(clip.startSeconds)}–{formatPodcastTime(clip.endSeconds)} · {clip.status}</p></div>
    {clip.error ? <p className="text-sm text-destructive">{clip.error}</p> : null}
    {media ? <PodcastClipPreview url={media.url} title={clip.title} onPlay={pauseMainAudio} onError={() => {
      URL.revokeObjectURL(media.url); objectUrls.current.delete(media.url); setMedia(null); setComposer(false);
      setError("Video Could Not Play. Please Retry Preview.");
    }} /> : null}
    {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
    {progress ? <p role="status" className="text-sm text-muted-foreground">{progress}</p> : null}
    {postUri ? <p role="status" className="text-sm">Published to Bluesky. <a className="text-primary underline" href={`/social/post?uri=${encodeURIComponent(postUri)}`}>View Post</a></p> : null}
    <div className="flex flex-wrap gap-2">
      <button className={button} disabled={busy || !ready} onClick={() => void run(async signal => { setProgress("Loading Video Preview"); await loadVideo(signal); })}>Preview Video</button>
      <button className={button} disabled={busy || !ready} onClick={() => void run(async signal => { setProgress("Loading Video Preview"); await loadVideo(signal); check(); setComposerVersion(value => value + 1); setComposer(true); })}>Post to Bluesky</button>
      {clip.status === "failed" ? <button className={button} disabled={busy} onClick={() => void run(async signal => {
        const oauth = requireSession();
        const job = clip.jobId ? { id: clip.jobId } : await podcastRequest<{ id: string }>(oauth, `jobs?clipId=${encodeURIComponent(clip.id)}`, "GET", undefined, signal);
        check(); await podcastRequest(oauth, "jobs", "POST", { jobId: job.id }, signal); check(); await onChanged?.();
      })}>Retry Exports</button> : null}
      {(["audio", "video"] as const).map(format => (format === "audio" ? clip.audioUrl : clip.videoUrl) ? <button key={format} className={button} disabled={busy} onClick={() => void run(async signal => {
        const blob = await fetchPodcastClipAsset({ session: requireSession(), clipId: clip.id, format, signal, assertCurrentAccount });
        check(); const url = URL.createObjectURL(blob); objectUrls.current.add(url);
        const anchor = document.createElement("a"); anchor.href = url; anchor.download = `${clip.title.replace(/[^a-z0-9 -]/gi, "").slice(0, 80) || "Podcast Clip"}.${format === "audio" ? "m4a" : "mp4"}`; anchor.click();
        const timer = setTimeout(() => { URL.revokeObjectURL(url); objectUrls.current.delete(url); exportTimers.current.delete(timer); }, 60000);
        exportTimers.current.add(timer);
      })}>{format === "audio" ? "Audio Export" : "Video Export"}</button> : null)}
      {!clip.publishedUri && episode ? <button className={button} disabled={busy || !ready || !clip.audioUrl || episode.visibility === "private"} onClick={() => void run(async () => { await publishPodcastClip(requireSession(), viewer!, clip, episode, assertCurrentAccount); check(); await onChanged?.(); })}>Publish Clip</button> : null}
      {clip.publishedUri ? <><a href={`/podcast-clips/${encodeURIComponent(clip.id)}`} className={button} target="_blank" rel="noreferrer">Public Clip</a>
        <button className={button} disabled={busy} onClick={() => void run(async () => { const url = `${location.origin}/podcast-clips/${encodeURIComponent(clip.id)}`; if (navigator.share) await navigator.share({ title: clip.title, url }); else await navigator.clipboard.writeText(url); })}>Share Clip</button>
        <button className={button} onClick={() => void navigator.clipboard.writeText(`<iframe src="${location.origin}/podcast-clips/${encodeURIComponent(clip.id)}/embed" title="Podcast Clip" width="480" height="200" loading="lazy" allow="autoplay"></iframe>`)}>Copy Embed</button></> : null}
      <button className={button} disabled={busy} onClick={() => { if (window.confirm("Delete This Clip? This removes its public record and hosted exports.")) void run(async () => { await unpublishPodcastClip(requireSession(), viewer!, clip, assertCurrentAccount); check(); await onChanged?.(); }); }}>Delete Clip</button>
    </div>
    {composer && media ? <PodcastClipComposer key={composerVersion} open onOpenChange={setComposer} title={clip.title} url={media.url} accountDid={viewer!} pending={busy} progress={progress} error={error} onPlay={pauseMainAudio} onCancel={() => { controller.current?.abort(); setBusy(false); setProgress(null); }}
      onPublish={text => void run(async signal => {
        const result = await publishBlueskyPodcastClip({ session: requireSession(), clip, video: media.blob, text, signal, assertCurrentAccount,
          onProgress: status => { check(); setProgress(status); } });
        check(); setPostUri(result.uri); setComposer(false);
      })} /> : null}
  </article>;
}
