"use client";
import { PodcastSelect } from "./PodcastSelect";
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
import Image from "next/image";
import { PodcastBridgeStatus } from "./PodcastBridgeStatus";
import { PodcastClips } from "./PodcastClips";
import { PodcastTranscripts } from "./PodcastTranscripts";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
const button =
  "min-h-11 rounded border px-3 text-sm hover:bg-accent disabled:opacity-50";
export function PodcastLibrary() {
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
  const [showDownloads, setShowDownloads] = useState(false);
  const [linkRss, setLinkRss] = useState("");
  const [linkProtocol, setLinkProtocol] = useState("");
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
      if (!navigator.onLine) setShowDownloads(true);
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
    if (!oauth || !showId) return;
    const controller = new AbortController();
    void podcastRequest<{ episodes: PodcastEpisode[]; cursor?: string }>(
      oauth,
      `episodes?showId=${encodeURIComponent(showId)}`,
      "GET",
      undefined,
      controller.signal,
    )
      .then((page) => {
        setEpisodes(page.episodes);
        setCursor(page.cursor);
      })
      .catch((reason) => {
        if (!controller.signal.aborted) setError(String(reason));
      });
    return () => controller.abort();
  }, [showId, getOAuthSession]);
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
      setError(reason instanceof Error ? reason.message : String(reason));
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
          : `Failed: ${reason instanceof Error ? reason.message : String(reason)}`,
      }));
    } finally {
      controllers.current.delete(item.id);
    }
  }
  const downloaded = new Set(downloads.map((item) => item.episode.id));
  const displayed = showDownloads
    ? downloads.map((item) => item.episode)
    : episodes;
  return (
    <div className="grid w-full min-w-0 gap-6 p-4 pb-60 md:grid-cols-[16rem_minmax(0,1fr)]">
      <section className="space-y-4">
        <h1 className="text-2xl font-semibold">Podcasts</h1>
        <form
          className="space-y-2"
          onSubmit={(event) => {
            event.preventDefault();
            void action(async () => {
              const oauth = getOAuthSession();
              if (!oauth || !session)
                throw new Error("Sign In to Add a Podcast");
              const resolved = await podcastRequest<{
                show?: PodcastShow;
                shows?: PodcastShow[];
                episodes: PodcastEpisode[];
              }>(oauth, "resolve", "POST", { url });
              const candidates =
                resolved.shows ?? (resolved.show ? [resolved.show] : []);
              setShows((current) => [
                ...current.filter(
                  (item) =>
                    !candidates.some((candidate) => candidate.id === item.id),
                ),
                ...candidates,
              ]);
              if (candidates[0]) {
                setShowId(candidates[0].id);
                setEpisodes(resolved.episodes);
              }
              setUrl("");
            });
          }}
        >
          <label
            className="block text-sm font-medium"
            htmlFor="podcast-feed-url"
          >
            Add a Podcast
          </label>
          <input
            id="podcast-feed-url"
            aria-describedby="podcast-feed-disclosure"
            value={url}
            onChange={(event) => setUrl(event.target.value)}
            placeholder="RSS URL, AT URI, or Account"
            className="min-h-11 w-full rounded border bg-background px-3 text-sm"
            required
          />
          <p
            id="podcast-feed-disclosure"
            className="text-xs text-muted-foreground"
          >
            Public RSS feeds are mirrored to AT Protocol with source
            attribution. Private feeds are not supported.
          </p>
          <button disabled={busy || !url.trim()} className={button}>
            Find Podcast
          </button>
        </form>
        <button
          className={button}
          aria-pressed={showDownloads}
          onClick={() => setShowDownloads((value) => !value)}
        >
          Downloads ({downloads.length})
        </button>
        <p className="text-xs text-muted-foreground">
          Storage:{" "}
          {(
            downloads.reduce((total, item) => total + item.bytes, 0) / 1048576
          ).toFixed(1)}{" "}
          MB. Browser storage may be evicted.
        </p>
        <ul className="space-y-2">
          {shows.map((show) => (
            <li key={show.id} className="rounded border p-3">
              <button
                className="flex w-full items-center gap-2 text-left font-medium"
                aria-current={show.id === showId ? "true" : undefined}
                onClick={() => {
                  setShowId(show.id);
                  setShowDownloads(false);
                }}
              >
                {show.artworkUrl ? (
                  <Image
                    unoptimized
                    src={show.artworkUrl}
                    alt=""
                    width={40}
                    height={40}
                    className="size-10 shrink-0 rounded object-cover"
                  />
                ) : null}
                <span className="min-w-0 break-words">{show.title}</span>
              </button>
              <p className="text-xs text-muted-foreground">
                {show.sourceKind === "rss" ? "RSS" : "AT Protocol"}
              </p>
              <button
                className="mt-2 min-h-9 text-sm underline"
                disabled={busy}
                onClick={() =>
                  void action(async () => {
                    const oauth = getOAuthSession();
                    if (!oauth || !session)
                      throw new Error("Sign In to Subscribe");
                    const remove = player.state.subscriptions.includes(show.id);
                    await writePodcastSubscription(
                      oauth,
                      session.did,
                      show,
                      remove,
                    );
                    await player.changeState({
                      subscriptions: remove
                        ? player.state.subscriptions.filter(
                            (id) => id !== show.id,
                          )
                        : [
                            ...new Set([
                              ...player.state.subscriptions,
                              show.id,
                            ]),
                          ],
                    });
                  })
                }
              >
                {player.state.subscriptions.includes(show.id)
                  ? "Unsubscribe"
                  : "Subscribe"}
              </button>
              <PodcastBridgeStatus
                show={show}
                subscribed={player.state.subscriptions.includes(show.id)}
              />
            </li>
          ))}
        </ul>
        {!shows.length ? (
          <p className="text-sm text-muted-foreground">
            Add an RSS feed or an on-protocol show to start listening.
          </p>
        ) : null}
        <details className="rounded border p-3">
          <summary className="cursor-pointer text-sm font-medium">
            Map RSS to AT Protocol
          </summary>
          <p className="my-2 text-xs text-muted-foreground">
            Link a resolved RSS show to its publisher record. Titles alone are
            never used to match shows.
          </p>
          <label className="block text-sm">
            RSS Show
            <PodcastSelect
              className="my-2 w-full rounded border bg-background p-2"
              value={linkRss}
              onChange={(event) => setLinkRss(event.target.value)}
            >
              <option value="">Choose RSS Show</option>
              {shows
                .filter((show) => show.sourceKind === "rss")
                .map((show) => (
                  <option key={show.id} value={show.id}>
                    {show.title}
                  </option>
                ))}
            </PodcastSelect>
          </label>
          <label className="block text-sm">
            Protocol Show
            <PodcastSelect
              className="my-2 w-full rounded border bg-background p-2"
              value={linkProtocol}
              onChange={(event) => setLinkProtocol(event.target.value)}
            >
              <option value="">Choose Protocol Show</option>
              {shows
                .filter((show) => show.sourceKind === "atproto")
                .map((show) => (
                  <option key={show.id} value={show.id}>
                    {show.title}
                  </option>
                ))}
            </PodcastSelect>
          </label>
          <button
            className={button}
            disabled={!linkRss || !linkProtocol || busy}
            onClick={() =>
              void action(() =>
                player.changeState({
                  manualLinks: [
                    ...player.state.manualLinks.filter(
                      (link) => link.rssShowId !== linkRss,
                    ),
                    { rssShowId: linkRss, protocolShowId: linkProtocol },
                  ],
                }),
              )
            }
          >
            Link Shows
          </button>
        </details>
      </section>
      <section className="min-w-0 space-y-5">
        {error ? (
          <p
            role="alert"
            className="rounded border border-destructive p-3 text-sm text-destructive"
          >
            {error}
          </p>
        ) : null}
        <h2 className="text-lg font-semibold">
          {showDownloads
            ? "Downloaded Episodes"
            : (shows.find((show) => show.id === showId)?.title ?? "Episodes")}
        </h2>
        <ul className="space-y-3">
          {displayed.map((item) => (
            <li key={item.id} className="rounded-xl border p-4">
              <div className="flex items-center gap-3">
                {item.artworkUrl ? (
                  <Image
                    unoptimized
                    src={item.artworkUrl}
                    alt=""
                    width={64}
                    height={64}
                    className="size-16 shrink-0 rounded-lg object-cover"
                  />
                ) : null}
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
                  onClick={() => void player.play(item)}
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
                      : "Download"}
                  </button>
                )}
              </div>
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
            {showDownloads
              ? "No Downloaded Episodes"
              : "Select a Podcast to See Its Episodes"}
          </p>
        ) : null}
        {cursor && !showDownloads ? (
          <button
            className={button}
            disabled={busy}
            onClick={() =>
              void action(async () => {
                const oauth = getOAuthSession();
                if (!oauth || !showId) return;
                const page = await podcastRequest<{
                  episodes: PodcastEpisode[];
                  cursor?: string;
                }>(
                  oauth,
                  `episodes?showId=${encodeURIComponent(showId)}&cursor=${encodeURIComponent(cursor)}`,
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
        <section aria-label="Podcast Queue" className="rounded border p-4">
          <h2 className="font-semibold">Up Next</h2>
          {player.state.queue.length ? (
            <ol className="mt-2 space-y-2">
              {player.state.queue.map((id, index) => (
                <li key={id} className="flex items-center gap-2 text-sm">
                  <span className="min-w-0 flex-1 truncate">
                    {episodes.find((item) => item.id === id)?.title ??
                      downloads.find((item) => item.episode.id === id)?.episode
                        .title ??
                      id}
                  </span>
                  <button
                    className={button}
                    disabled={index === 0}
                    onClick={() => {
                      const queue = [...player.state.queue];
                      [queue[index - 1], queue[index]] = [
                        queue[index],
                        queue[index - 1],
                      ];
                      void player.changeState({ queue });
                    }}
                  >
                    Move Up
                  </button>
                  <button
                    className={button}
                    onClick={() =>
                      void player.changeState({
                        queue: player.state.queue.filter(
                          (value) => value !== id,
                        ),
                      })
                    }
                  >
                    Remove
                  </button>
                </li>
              ))}
            </ol>
          ) : (
            <p className="mt-2 text-sm text-muted-foreground">Queue Is Empty</p>
          )}
        </section>
        {player.episode ? (
          <section className="space-y-5 rounded-xl border p-4">
            <h2 className="text-lg font-semibold">
              Now Playing: {player.episode.title}
            </h2>
            <PodcastTranscripts transcripts={transcripts} />
            <PodcastClips key={player.episode.id} episode={player.episode} />
          </section>
        ) : null}
      </section>
    </div>
  );
}
