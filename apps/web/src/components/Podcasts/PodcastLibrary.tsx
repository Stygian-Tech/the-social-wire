"use client";
import { PodcastLibrarySidebar } from "./PodcastLibrarySidebar";
import { podcastFeedEpisodes, type PodcastFeed } from "@/lib/podcasts/library";
import { savePodcastAudioToDevice } from "@/lib/podcasts/deviceDownload";
import { useCallback, useEffect, useRef, useState } from "react";
import { usePodcastViewer } from "@/hooks/usePodcastViewer";
import { useAuth } from "@/hooks/useAuth";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import {
  podcastMediaPath,
  podcastRequest,
  writePodcastSubscription,
  type PodcastEpisode,
  type PodcastShow,
  type PodcastTranscript,
  type PodcastSilence,
} from "@/lib/podcasts/client";
import {
  deletePodcastDownload,
  getPodcastDownload,
  listPodcastDownloads,
  savePodcastDownload,
  type PodcastDownload,
} from "@/lib/podcasts/offline";
import { formatPodcastTime } from "@/lib/podcasts/playback";
import { PodcastArtwork } from "./PodcastArtwork";
import { PodcastShowDetails } from "./PodcastShowDetails";
import { PodcastChapters } from "./PodcastChapters";
import { PodcastClips } from "./PodcastClips";
import { PodcastTranscripts } from "./PodcastTranscripts";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
const button =
  "min-h-11 rounded border px-3 text-sm hover:bg-accent disabled:opacity-50";
export function PodcastLibrary() {
  const viewer = usePodcastViewer();
  return <PodcastViewerLibrary key={viewer ?? "signed-out"} />;
}
function PodcastViewerLibrary() {
  const { session, getOAuthSession } = useAuth();
  const viewer = usePodcastViewer();
  const player = usePodcastPlayer();
  const [shows, setShows] = useState<PodcastShow[]>([]);
  const [showId, setShowId] = useState<string | null>(null);
  const [episodes, setEpisodes] = useState<PodcastEpisode[]>([]);
  const [cursor, setCursor] = useState<string | undefined>();
  const [url, setUrl] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [transcripts, setTranscripts] = useState<PodcastTranscript[]>([]);
  const [downloads, setDownloads] = useState<PodcastDownload[]>([]);
  const [downloadStatus, setDownloadStatus] = useState<Record<string, string>>(
    {},
  );
  const [feed, setFeed] = useState<PodcastFeed>("recent");
  const [privateFeed, setPrivateFeed] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  const [loading, setLoading] = useState(false);
  const [preparingEpisode, setPreparingEpisode] = useState<string | null>(null);
  const controllers = useRef(new Map<string, AbortController>());
  const libraryGeneration = useRef(0);
  const cancelLibraryLoad = useCallback(() => {
    libraryGeneration.current++;
  }, []);
  const load = useCallback(async () => {
    const oauth = getOAuthSession();
    if (!viewer) return;
    const generation = ++libraryGeneration.current;
    const [catalog, local] = await Promise.allSettled([
      oauth && navigator.onLine
        ? podcastRequest<{ shows: PodcastShow[] }>(oauth, "shows")
        : Promise.resolve({ shows: [] }),
      listPodcastDownloads(viewer),
    ]);
    if (generation !== libraryGeneration.current) return;
    if (catalog.status === "fulfilled") setShows(catalog.value.shows);
    else if (navigator.onLine) setError(String(catalog.reason));
    if (local.status === "fulfilled") {
      setDownloads(local.value);
      if (!navigator.onLine) setFeed("downloads");
    }
  }, [getOAuthSession, viewer]);
  useEffect(() => {
    void load();
    const current = controllers.current;
    return () => {
      cancelLibraryLoad();
      for (const controller of current.values()) controller.abort();
    };
  }, [load, cancelLibraryLoad]);
  useEffect(() => {
    const oauth = getOAuthSession();
    if (!oauth || !navigator.onLine || feed === "downloads" || (feed === "show" && !showId)) return;
    const controller = new AbortController();
    const path = feed === "show"
      ? `episodes?showId=${encodeURIComponent(showId!)}`
      : "episodes";
    setLoading(true);
    setCursor(undefined);
    const request = podcastRequest<{ episodes: PodcastEpisode[]; cursor?: string }>(
      oauth, feed === "queue" ? "episodes?queue=true" : path,
      "GET", undefined, controller.signal,
    );
    void request.then((page) => {
      if (controller.signal.aborted) return;
      setEpisodes(page.episodes);
      setCursor(page.cursor);
    }).catch((reason) => {
      if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "Episodes Could Not Load. Please Retry.");
    }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [showId, feed, getOAuthSession, player.state.queue, player.state.subscriptions, downloads]);
  useEffect(() => {
    const oauth = getOAuthSession();
    if (!viewer || !player.episode) return;
    let cancelled = false;
    void (
      oauth && navigator.onLine
        ? podcastRequest<{ transcripts: PodcastTranscript[] }>(
            oauth,
            `transcript?episodeId=${encodeURIComponent(player.episode.id)}`,
          )
        : Promise.reject(new Error("Offline"))
    )
      .then((result) => {
        if (!cancelled) setTranscripts(result.transcripts);
      })
      .catch(async () => {
        if (!viewer || !player.episode) return;
        const local = await getPodcastDownload(viewer, player.episode.id).catch(
          () => undefined,
        );
        if (!cancelled)
          setTranscripts(
            local?.transcripts ??
              (local?.transcript
                ? [local.transcript]
                : player.episode.transcripts),
          );
      });
    return () => {
      cancelled = true;
    };
  }, [player.episode, getOAuthSession, viewer]);
  async function action(run: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await run();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Podcast Action Failed. Please Retry.");
    } finally {
      setBusy(false);
    }
  }
  async function download(item: PodcastEpisode) {
    const oauth = getOAuthSession();
    if (!oauth || !session) return;
    const did = session.did;
    const controller = new AbortController();
    controllers.current.set(item.id, controller);
    setDownloadStatus((current) => ({ ...current, [item.id]: "Downloading…" }));
    try {
      const [response, transcript, silence] = await Promise.all([
        gatewayFetch(oauth, `/v1/podcasts/${podcastMediaPath(item.id)}`, {
          signal: controller.signal,
        }),
        podcastRequest<{ transcripts: PodcastTranscript[] }>(
          oauth,
          `transcript?episodeId=${encodeURIComponent(item.id)}`,
        ).catch(() => ({ transcripts: item.transcripts })),
        podcastRequest<PodcastSilence>(
          oauth,
          `analysis?episodeId=${encodeURIComponent(item.id)}`,
        ).catch(() => undefined),
      ]);
      if (!response.ok) throw new Error(`Download Failed (${response.status})`);
      const media = await response.blob();
      if (controller.signal.aborted) return;
      if (!media.size) throw new Error("The audio file was empty");
      await savePodcastDownload(
        did,
        {
          episode: item,
          bytes: media.size,
          downloadedAt: new Date().toISOString(),
          transcript: transcript.transcripts[0],
          transcripts: transcript.transcripts,
          silence,
        },
        media,
      );
      if (controller.signal.aborted) return;
      setDownloadStatus((current) => ({ ...current, [item.id]: "Downloaded" }));
      await load();
    } catch (reason) {
      setDownloadStatus((current) => ({
        ...current,
        [item.id]: controller.signal.aborted
          ? "Cancelled"
          : `Failed: ${reason instanceof Error ? reason.message : "Podcast Action Failed. Please Retry."}`,
      }));
    } finally {
      controllers.current.delete(item.id);
    }
  }
  const downloaded = new Set(downloads.map((item) => item.episode.id));
  const displayed = podcastFeedEpisodes(feed, episodes, downloads.map((item) => item.episode), player.state.queue);
  const selectedShow = feed === "show" ? shows.find((show) => show.id === showId) : undefined;
  const heading = selectedShow?.title ?? ({ recent: "Recently Added", downloads: "Downloaded", queue: "Up Next", show: "Episodes" }[feed]);
  const selectFeed = (next: PodcastFeed, id?: string) => {
    setFeed(next);
    setShowId(id ?? null);
    setEpisodes([]);
    setCursor(undefined);
    setError(null);
  };
  async function subscribe(show: PodcastShow) {
    await action(async () => {
      const oauth = getOAuthSession();
      if (!oauth || !session) throw new Error("Sign In to Subscribe");
      const remove = player.state.subscriptions.includes(show.id);
      await writePodcastSubscription(oauth, session.did, show, remove);
      await player.changeState({ subscriptions: remove
        ? player.state.subscriptions.filter((id) => id !== show.id)
        : [...new Set([...player.state.subscriptions, show.id])] });
      if (show.visibility === "private" && remove) {
        setShows((current) => current.filter((item) => item.id !== show.id));
        selectFeed("recent");
      }
    });
  }
  async function playEpisode(item: PodcastEpisode) {
    if (item.visibility === "private") setPreparingEpisode(item.id);
    try { await player.play(item); }
    finally { setPreparingEpisode((id) => id === item.id ? null : id); }
  }
  async function saveAudio(item: PodcastEpisode) {
    if (!viewer) return;
    try {
      const result = await savePodcastAudioToDevice(viewer, item, async () => {
        const oauth = getOAuthSession();
        if (!oauth) throw new Error("Sign In to Save Audio That Is Not Downloaded");
        return gatewayFetch(oauth, `/v1/podcasts/${podcastMediaPath(item.id)}`);
      });
      setDownloadStatus((current) => ({ ...current, [item.id]: result === "cancelled" ? "Save Cancelled" : "Saved to Device" }));
    } catch { setError("Audio Could Not Be Saved. Please Retry."); }
  }
  return (
    <div className="mx-auto grid w-full min-w-0 max-w-7xl grid-cols-1 gap-6 p-4 pb-60 lg:grid-cols-[minmax(0,1fr)_18rem] lg:p-6 lg:pb-60">
      <section className="min-w-0 space-y-5">
        <header className="flex flex-wrap items-center justify-between gap-3">
          <h1 className="text-2xl font-semibold">Podcasts</h1>
          <button type="button" className={button} aria-expanded={showAdd} onClick={() => setShowAdd((value) => !value)}>Add a Podcast</button>
        </header>
        {showAdd ? <form className="min-w-0 space-y-3 rounded-xl border p-4" onSubmit={(event) => {
          event.preventDefault();
          void action(async () => {
            const oauth = getOAuthSession();
            if (!oauth || !session) throw new Error("Sign In to Add a Podcast");
            const resolved = await podcastRequest<{ show?: PodcastShow; shows?: PodcastShow[]; episodes: PodcastEpisode[] }>(oauth, privateFeed ? "private/resolve" : "resolve", "POST", { url });
            const candidates = resolved.shows ?? (resolved.show ? [resolved.show] : []);
            setShows((current) => [...current.filter((item) => !candidates.some((candidate) => candidate.id === item.id)), ...candidates]);
            if (candidates[0]) {
              selectFeed("show", candidates[0].id);
              setEpisodes(resolved.episodes);
              if (privateFeed) await player.changeState({ subscriptions: [...new Set([...player.state.subscriptions, candidates[0].id])] });
            }
            setUrl("");
            setShowAdd(false);
          });
        }}>
          <label className="block text-sm font-medium" htmlFor="podcast-feed-url">{privateFeed ? "Private RSS Feed URL" : "RSS URL, AT URI, or Account"}</label>
          <div className="flex min-w-0 flex-col gap-2 sm:flex-row">
            <input id="podcast-feed-url" type={privateFeed ? "url" : "text"} aria-describedby="podcast-feed-disclosure" value={url} onChange={(event) => setUrl(event.target.value)} placeholder={privateFeed ? "https://example.com/private-feed" : "Feed URL or AT Protocol Account"} className="min-h-11 w-full min-w-0 flex-1 rounded-lg border bg-background px-3 text-sm" required />
            <button disabled={busy || !url.trim()} className={button}>{busy ? "Finding…" : privateFeed ? "Subscribe" : "Find Podcast"}</button>
          </div>
          <label className="flex min-h-9 items-center gap-2 text-sm"><input type="checkbox" checked={privateFeed} onChange={(event) => setPrivateFeed(event.target.checked)} />Private Feed</label>
          <p id="podcast-feed-disclosure" className="text-xs text-muted-foreground">{privateFeed ? "Saved privately to your account. No public subscription record is created." : "Subscribe with an RSS feed or AT Protocol account. For paid or tokenized RSS feeds, choose Private Feed."}</p>
        </form> : null}
        {error || player.error ? (
          <p
            role="alert"
            className="rounded border border-destructive p-3 text-sm text-destructive"
          >
            {error ?? player.error}
          </p>
        ) : null}
        {selectedShow ? <PodcastShowDetails show={selectedShow} /> : <h2 className="text-lg font-semibold">{heading}</h2>}
        {selectedShow ? <div className="space-y-2">
          <button type="button" className={button} disabled={busy} onClick={() => void subscribe(selectedShow)}>{player.state.subscriptions.includes(selectedShow.id) ? "Unsubscribe" : "Subscribe"}</button>
          {selectedShow.visibility === "private" ? <button type="button" className={button} disabled={busy} onClick={() => void action(async () => {
            const oauth = getOAuthSession();
            if (!oauth) return;
            await podcastRequest(oauth, "private/refresh", "POST", { showId: selectedShow.id });
            const page = await podcastRequest<{ episodes: PodcastEpisode[]; cursor?: string }>(oauth, `episodes?showId=${encodeURIComponent(selectedShow.id)}`);
            setEpisodes(page.episodes);
            setCursor(page.cursor);
          })}>Refresh Feed</button> : null}
          {selectedShow.visibility === "private" ? <p className="text-xs text-muted-foreground">Private Feed</p> : null}
        </div> : null}
        {loading ? <p role="status" className="text-sm text-muted-foreground">Loading Episodes…</p> : null}
        <ul className="space-y-3">
          {displayed.map((item) => (
            <li key={item.id} className="rounded-xl border p-4">
              <div className="flex items-center gap-3">
                <PodcastArtwork src={item.artworkUrl ?? item.showArtworkUrl} alt="" size={64} className="size-16" />
                <h3 className="font-semibold">{item.title}</h3>
              </div>
              <p className="mt-1 text-xs text-muted-foreground">
                {item.publishedAt
                  ? new Date(item.publishedAt).toLocaleDateString()
                  : ""}{" "}
                {item.durationSeconds
                  ? `· ${formatPodcastTime(item.durationSeconds)}`
                  : ""}
              </p>
              {item.description ? (
                <p className="mt-2 line-clamp-3 text-sm text-muted-foreground">
                  {item.description.replace(/<[^>]*>/g, " ")}
                </p>
              ) : null}
              <div className="mt-3 flex flex-wrap gap-2">
                <button
                  className={button}
                  disabled={preparingEpisode === item.id}
                  onClick={() => void playEpisode(item)}
                >
                  Play
                </button>
                <button
                  className={button}
                  onClick={() =>
                    void player.changeState({
                      queue: [...new Set([...player.state.queue, item.id])],
                    })
                  }
                >
                  Add to Queue
                </button>
                <button
                  className={button}
                  onClick={() =>
                    void player.changeState({
                      progress: {
                        [item.id]: {
                          positionSeconds:
                            player.state.progress[item.id]?.positionSeconds ??
                            0,
                          completed: !player.state.progress[item.id]?.completed,
                          updatedAt: new Date().toISOString(),
                        },
                      },
                    })
                  }
                >
                  {player.state.progress[item.id]?.completed
                    ? "Mark Unplayed"
                    : "Mark Played"}
                </button>
                <button type="button" className={button} onClick={() => void saveAudio(item)}>Save Audio</button>
                {feed === "queue" ? <button type="button" className={button} disabled={player.state.queue.indexOf(item.id) <= 0} onClick={() => {
                  const queue = [...player.state.queue];
                  const index = queue.indexOf(item.id);
                  if (index <= 0) return;
                  [queue[index - 1], queue[index]] = [queue[index], queue[index - 1]];
                  void player.changeState({ queue });
                }}>Move Up</button> : null}
                {feed === "queue" ? <button type="button" className={button} onClick={() => void player.changeState({ queue: player.state.queue.filter((id) => id !== item.id) })}>Remove from Queue</button> : null}
                {controllers.current.has(item.id) ? (
                  <button
                    className={button}
                    onClick={() => controllers.current.get(item.id)?.abort()}
                  >
                    Cancel Download
                  </button>
                ) : downloaded.has(item.id) ? (
                  <button
                    className={button}
                    onClick={() => {
                      if (window.confirm("Delete This Download?"))
                        void action(async () => {
                          if (!session) return;
                          await deletePodcastDownload(session.did, item.id);
                          await load();
                        });
                    }}
                  >
                    Delete Download
                  </button>
                ) : (
                  <button
                    className={button}
                    onClick={() => void download(item)}
                  >
                    {downloadStatus[item.id]?.startsWith("Failed")
                      ? "Retry Download"
                      : "Download for Offline"}
                  </button>
                )}
              </div>
              {preparingEpisode === item.id ? <p role="status" className="mt-2 text-xs">Preparing Private Audio…</p> : null}
              {downloadStatus[item.id] ? (
                <p className="mt-2 text-xs" role="status">
                  {downloadStatus[item.id]}
                </p>
              ) : null}
            </li>
          ))}
        </ul>
        {!displayed.length ? (
          <p className="text-sm text-muted-foreground">
            {loading ? "" : feed === "downloads" ? "No Downloaded Episodes" : feed === "queue" ? "Queue Is Empty" : feed === "recent" ? "Subscribe to a Podcast to See New Episodes" : "No Episodes Available"}
          </p>
        ) : null}
        {cursor && (feed === "show" || feed === "recent") ? (
          <button
            className={button}
            disabled={busy}
            onClick={() =>
              void action(async () => {
                const oauth = getOAuthSession();
                if (!oauth) return;
                const page = await podcastRequest<{
                  episodes: PodcastEpisode[];
                  cursor?: string;
                }>(
                  oauth,
                  `episodes?${feed === "show" && showId ? `showId=${encodeURIComponent(showId)}&` : ""}cursor=${encodeURIComponent(cursor)}`,
                );
                setEpisodes((current) => [
                  ...current,
                  ...page.episodes.filter(
                    (item) =>
                      !current.some((existing) => existing.id === item.id),
                  ),
                ]);
                setCursor(page.cursor);
              })
            }
          >
            Load More Episodes
          </button>
        ) : null}
        {player.episode ? (
          <section className="space-y-5 rounded-xl border p-4">
            <h2 className="text-lg font-semibold">
              Now Playing: {player.episode.title}
            </h2>
            <PodcastChapters chapters={player.episode.chapters} position={player.position} onSeek={player.seek} />
            <PodcastTranscripts transcripts={transcripts} />
            {player.episode.visibility !== "private" ? <PodcastClips key={player.episode.id} episode={player.episode} /> : <p className="text-sm text-muted-foreground">Clips Are Unavailable for Private Feeds</p>}
          </section>
        ) : null}
        {feed === "downloads" ? <p className="text-xs text-muted-foreground">Offline Audio: {(downloads.reduce((total, item) => total + item.bytes, 0) / 1048576).toFixed(1)} MB. Save Audio exports a file to your device.</p> : null}
      </section>
      <div className="min-w-0 self-start lg:col-start-2 lg:row-start-1">
        <PodcastLibrarySidebar feed={feed} showId={showId} shows={shows} subscriptions={player.state.subscriptions} downloadCount={downloads.length} queueCount={player.state.queue.length} onSelect={selectFeed} />
      </div>
    </div>
  );
}
