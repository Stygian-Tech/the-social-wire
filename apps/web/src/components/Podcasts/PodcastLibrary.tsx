"use client";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { PodcastClipsLibrary } from "./PodcastClipsLibrary";
import { PodcastPlaybackDefaults } from "./PodcastPlaybackDefaults";
import { PodcastLibrarySearch } from "./PodcastLibrarySearch";
import { PodcastUnsubscribeDialog } from "./PodcastUnsubscribeDialog";
import { PodcastLibrarySidebar } from "./PodcastLibrarySidebar";
import { podcastFeedEpisodes, type PodcastFeed } from "@/lib/podcasts/library";
import { savePodcastAudioToDevice } from "@/lib/podcasts/deviceDownload";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, ArrowUp, CheckCircle, Circle, Download, HardDriveDownload, ListPlus, ListX, Minus, Play, Plus, RotateCw, Trash2, X } from "lucide-react";
import { PodcastEpisodeActionButton } from "./PodcastEpisodeActionButton";
import { PodcastDirectoryResults } from "./PodcastDirectoryResults";
import { usePodcastLibrarySearch, type PodcastDirectoryCandidate } from "@/hooks/usePodcastLibrarySearch";
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
  listPodcastDownloads,
  savePodcastDownload,
  type PodcastDownload,
} from "@/lib/podcasts/offline";
import { PodcastEpisodeProgress } from "./PodcastEpisodeProgress";
import { PodcastEpisodeDetailsDialog } from "./PodcastEpisodeDetailsDialog";
import { PodcastShowDetails } from "./PodcastShowDetails";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
const button =
  "min-h-11 rounded border px-3 text-sm hover:bg-accent disabled:opacity-50";
const compactButton = "inline-flex min-h-8 shrink-0 items-center gap-1.5 rounded border px-2 text-xs hover:bg-accent disabled:opacity-50 pointer-coarse:min-h-11";
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
  const [unsubscribeShow, setUnsubscribeShow] = useState<PodcastShow | null>(null);
  const [downloads, setDownloads] = useState<PodcastDownload[]>([]);
  const [downloadStatus, setDownloadStatus] = useState<Record<string, string>>(
    {},
  );
  const [feed, setFeed] = useState<PodcastFeed>("recent");
  const [privateFeed, setPrivateFeed] = useState(false);
  const [searchScope, setSearchScope] = useState<"library" | "discover">("library");
  const [searchQuery, setSearchQuery] = useState("");
  // Keep directory search mounted while previewing so Back restores the same results.
  const [previewShowId, setPreviewShowId] = useState<string | null>(null);
  const [directoryShows, setDirectoryShows] = useState<Record<string, PodcastShow>>({});
  const [showAdd, setShowAdd] = useState(false);
  const [loading, setLoading] = useState(false);
  const [preparingEpisode, setPreparingEpisode] = useState<string | null>(null);
  const downloadEpisodes = useMemo(() => downloads.map(item => item.episode), [downloads]);
  const searching = feed !== "clips" && !previewShowId && (searchScope === "discover" || !!searchQuery.trim());
  const search = usePodcastLibrarySearch({ viewer, query: feed === "clips" ? "" : searchQuery, scope: searchScope === "discover" ? "directory" : "library", showId: searchScope === "library" && feed === "show" ? showId ?? undefined : undefined, downloaded: searchScope === "library" && feed === "downloads" ? downloadEpisodes : undefined, getOAuthSession });
  const showNames = useMemo(() => new Map([...shows, ...search.shows].map(show => [show.id, show.title.trim()])), [shows, search.shows]);
  const controllers = useRef(new Map<string, AbortController>());
  useEffect(() => () => controllers.current.get("directory-action")?.abort(), [searchQuery, searchScope]);
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
    if (feed === "clips" || searching || !oauth || !navigator.onLine || feed === "downloads" || (feed === "show" && !showId)) return;
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
  }, [showId, feed, getOAuthSession, player.state.queue, player.state.subscriptions, downloads, searching]);
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
  async function resolveDirectory(candidate: PodcastDirectoryCandidate, subscribeImmediately = false) {
    const oauth = getOAuthSession();
    if (!viewer || oauth?.did !== viewer) { setError("Account Is Loading. Please Retry."); return; }
    const controller = new AbortController();
    controllers.current.get("directory-action")?.abort();
    controllers.current.set("directory-action", controller);
    setBusy(true);
    setError(null);
    try {
      const resolved = await podcastRequest<{ show: PodcastShow; episodes: PodcastEpisode[] }>(oauth, "resolve", "POST", { url: candidate.feedUrl }, controller.signal);
      if (controller.signal.aborted || getOAuthSession()?.did !== viewer) return;
      setShows(current => [...current.filter(show => show.id !== resolved.show.id), resolved.show]);
      setDirectoryShows(current => ({ ...current, [candidate.feedUrl]: resolved.show }));
      if (subscribeImmediately) {
        if (!player.state.subscriptions.includes(resolved.show.id)) {
          await writePodcastSubscription(oauth, viewer, resolved.show, false);
          if (getOAuthSession()?.did !== viewer) return;
          await player.changeState({ subscriptions: [...new Set([...player.state.subscriptions, resolved.show.id])] });
        }
      } else {
        setPreviewShowId(resolved.show.id);
        setFeed("show");
        setShowId(resolved.show.id);
        setEpisodes(resolved.episodes);
      }
    } catch {
      if (!controller.signal.aborted) setError(subscribeImmediately ? "Podcast Could Not Be Subscribed. Please Retry." : "Podcast Preview Could Not Load. Please Retry.");
    } finally {
      if (controllers.current.get("directory-action") === controller) {
        controllers.current.delete("directory-action");
        setBusy(false);
      }
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
  const displayed = searching ? search.episodes : podcastFeedEpisodes(feed, episodes, downloadEpisodes, player.state.queue);
  const selectedShow = (previewShowId || (searchScope === "library" && feed === "show")) ? shows.find((show) => show.id === showId) : undefined;
  const heading = searchScope === "discover" ? "Search Podcasts" : selectedShow?.title ?? ({ recent: "Recently Added", downloads: "Downloaded", queue: "Up Next", show: "Episodes", clips: "Clips" }[feed]);
  const selectFeed = (next: PodcastFeed, id?: string) => {
    setPreviewShowId(null);
    if (searchScope === "discover") { setSearchScope("library"); setSearchQuery(""); }
    setSearchQuery("");
    setFeed(next);
    setShowId(id ?? null);
    setEpisodes([]);
    setCursor(undefined);
    setError(null);
  };
  async function changeSubscription(show: PodcastShow, remove: boolean) {
    const oauth = getOAuthSession();
    if (!oauth || oauth.did !== viewer) throw new Error("Sign In to Subscribe");
    await writePodcastSubscription(oauth, oauth.did, show, remove);
    if (getOAuthSession()?.did !== viewer) return;
    await player.changeState({ subscriptions: remove
      ? player.state.subscriptions.filter((id) => id !== show.id)
      : [...new Set([...player.state.subscriptions, show.id])] });
    if (remove) {
      if (show.visibility === "private") setShows((current) => current.filter((item) => item.id !== show.id));
      if (feed === "show" && showId === show.id) selectFeed("recent");
    }
  }
  async function subscribe(show: PodcastShow) {
    if (player.state.subscriptions.includes(show.id)) {
      setUnsubscribeShow(show);
      return;
    }
    await action(() => changeSubscription(show, false));
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
    <div className="grid w-full min-w-0 grid-cols-1 gap-4 p-4 lg:h-full lg:min-h-0 lg:grid-cols-[minmax(0,1fr)_18rem] lg:grid-rows-[minmax(0,1fr)] lg:overflow-hidden">
      <section className="min-w-0 lg:flex lg:min-h-0 lg:flex-col">
        <FeedHeader title="Podcasts" className="m-0 mb-4">
          <div className="flex items-center gap-2">
            <PodcastPlaybackDefaults player={player} />
            <button type="button" className="inline-flex min-h-7 shrink-0 items-center gap-1 rounded border px-1.5 text-xs hover:bg-accent pointer-coarse:min-h-11" aria-expanded={showAdd} onClick={() => setShowAdd((value) => !value)}><Plus aria-hidden="true" className="size-3.5" />Add a Podcast</button>
          </div>
        </FeedHeader>
        <div className="space-y-5 overscroll-contain lg:min-h-0 lg:flex-1 lg:overflow-y-auto">
        {feed === "clips" ? <PodcastClipsLibrary /> : <>
        {!previewShowId ? <PodcastLibrarySearch
          scope={searchScope}
          query={searchQuery}
          label={searchScope === "discover" ? "Search Podcasts" : feed === "downloads" ? "Search Downloaded Episodes" : feed === "show" ? "Search This Show" : "Search Your Library"}
          valid={search.valid}
          loading={search.loading}
          error={search.error}
          shows={search.shows}
          onQuery={setSearchQuery}
          onRetry={search.retry}
          onShow={show => {
            setShows(current => [...current.filter(item => item.id !== show.id), show]);
            setSearchQuery("");
            selectFeed("show", show.id);
          }}
        /> : null}
        {searchScope === "discover" && !previewShowId ? <PodcastDirectoryResults
          candidates={search.candidates ?? []}
          directoryLimit={search.directoryLimit ?? 50}
          query={searchQuery}
          loading={search.loading}
          failed={!!search.error}
          busy={busy}
          onPreview={candidate => void resolveDirectory(candidate)}
          onSubscribe={candidate => void resolveDirectory(candidate, true)}
          isSubscribed={candidate => player.state.subscriptions.includes(directoryShows[candidate.feedUrl]?.id ?? shows.find(show => show.feedUrl === candidate.feedUrl)?.id ?? "")}
        /> : null}
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
        {previewShowId ? <button type="button" className={compactButton} onClick={() => {
          setPreviewShowId(null);
          setFeed("recent");
          setShowId(null);
          setEpisodes([]);
          setCursor(undefined);
          setError(null);
        }}><ArrowLeft aria-hidden="true" className="size-3.5" />Back to Search</button> : null}
        {selectedShow ? <PodcastShowDetails show={selectedShow} action={
          <button type="button" className={`${compactButton} ${player.state.subscriptions.includes(selectedShow.id) ? "text-destructive" : ""}`} disabled={busy} onClick={() => void subscribe(selectedShow)}>
            {player.state.subscriptions.includes(selectedShow.id) ? <Minus aria-hidden="true" className="size-3.5" /> : <Plus aria-hidden="true" className="size-3.5" />}
            {player.state.subscriptions.includes(selectedShow.id) ? "Unsubscribe" : "Subscribe"}
          </button>
        } /> : <h2 className="text-lg font-semibold">{heading}</h2>}
        {selectedShow?.visibility === "private" ? <div className="space-y-2">
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
        {searching && search.episodes.length ? <h2 className="text-lg font-semibold">Matching Episodes</h2> : null}
        {!searching && loading ? <p role="status" className="text-sm text-muted-foreground">Loading Episodes…</p> : null}
        <ul className="space-y-3">
          {displayed.map((item) => (
            <li key={item.id} data-played={!!player.state.progress[item.id]?.completed} className="rounded-xl border p-4 transition-colors hover:bg-accent/30 focus-within:bg-accent/30 data-[played=true]:border-border/60 data-[played=true]:bg-muted/40 data-[played=true]:hover:bg-accent/30 data-[played=true]:focus-within:bg-accent/30">
              <PodcastEpisodeDetailsDialog episode={item} played={!!player.state.progress[item.id]?.completed} inProgress={(player.episode?.id === item.id ? player.position : player.state.progress[item.id]?.positionSeconds ?? 0) > 0} showName={showNames.get(item.showId)} onTimecode={seconds => {
                if (player.episode?.id === item.id) player.seek(seconds);
                else void player.play(item, seconds);
              }} />
              <PodcastEpisodeProgress position={player.episode?.id === item.id ? player.position : player.state.progress[item.id]?.positionSeconds ?? 0} duration={player.episode?.id === item.id ? player.duration || item.durationSeconds : item.durationSeconds} completed={!!player.state.progress[item.id]?.completed} />
              <div className="mt-3 flex flex-wrap gap-1.5">
                <PodcastEpisodeActionButton
                  icon={Play}
                  disabled={preparingEpisode === item.id}
                  onClick={() => void playEpisode(item)}
                >
                  Play
                </PodcastEpisodeActionButton>
                <PodcastEpisodeActionButton
                  icon={ListPlus}
                  onClick={() =>
                    void player.changeState({
                      queue: [...new Set([...player.state.queue, item.id])],
                    })
                  }
                >
                  Add to Queue
                </PodcastEpisodeActionButton>
                <PodcastEpisodeActionButton
                  icon={player.state.progress[item.id]?.completed ? Circle : CheckCircle}
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
                </PodcastEpisodeActionButton>
                <PodcastEpisodeActionButton icon={Download} onClick={() => void saveAudio(item)}>Save Audio</PodcastEpisodeActionButton>
                {feed === "queue" ? <PodcastEpisodeActionButton icon={ArrowUp} disabled={player.state.queue.indexOf(item.id) <= 0} onClick={() => {
                  const queue = [...player.state.queue];
                  const index = queue.indexOf(item.id);
                  if (index <= 0) return;
                  [queue[index - 1], queue[index]] = [queue[index], queue[index - 1]];
                  void player.changeState({ queue });
                }}>Move Up</PodcastEpisodeActionButton> : null}
                {feed === "queue" ? <PodcastEpisodeActionButton icon={ListX} onClick={() => void player.changeState({ queue: player.state.queue.filter((id) => id !== item.id) })}>Remove from Queue</PodcastEpisodeActionButton> : null}
                {controllers.current.has(item.id) ? (
                  <PodcastEpisodeActionButton
                    icon={X}
                    onClick={() => controllers.current.get(item.id)?.abort()}
                  >
                    Cancel Download
                  </PodcastEpisodeActionButton>
                ) : downloaded.has(item.id) ? (
                  <PodcastEpisodeActionButton
                    icon={Trash2}
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
                  </PodcastEpisodeActionButton>
                ) : (
                  <PodcastEpisodeActionButton
                    icon={downloadStatus[item.id]?.startsWith("Failed") ? RotateCw : HardDriveDownload}
                    onClick={() => void download(item)}
                  >
                    {downloadStatus[item.id]?.startsWith("Failed")
                      ? "Retry Download"
                      : "Download for Offline"}
                  </PodcastEpisodeActionButton>
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
        {searchScope === "library" && searching && search.valid && !search.loading && !search.error && !search.shows.length && !search.episodes.length ? <p className="text-sm text-muted-foreground">No Matching Shows or Episodes{search.hasMore ? " on This Page" : ""}</p> : null}
        {!searching && !displayed.length ? (
          <p className="text-sm text-muted-foreground">
            {loading ? "" : feed === "downloads" ? "No Downloaded Episodes" : feed === "queue" ? "Queue Is Empty" : feed === "recent" ? "Subscribe to a Podcast to See New Episodes" : "No Episodes Available"}
          </p>
        ) : null}
        {searching && search.hasMore && search.cursor ? <button type="button" className={button} disabled={search.loading} onClick={() => void search.loadMore()}>Load More Results</button> : null}
        {!searching && cursor && (feed === "show" || feed === "recent") ? (
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
        {feed === "downloads" ? <p className="text-xs text-muted-foreground">Offline Audio: {(downloads.reduce((total, item) => total + item.bytes, 0) / 1048576).toFixed(1)} MB. Save Audio exports a file to your device.</p> : null}
        </>}
        </div>
      </section>
      <div className="min-w-0 lg:col-start-2 lg:row-start-1 lg:flex lg:min-h-0 lg:flex-col lg:overflow-hidden">
        <PodcastUnsubscribeDialog key={unsubscribeShow?.id ?? "closed"} show={unsubscribeShow} onClose={() => setUnsubscribeShow(null)} onConfirm={async (show) => {
          setBusy(true);
          try { await changeSubscription(show, true); }
          finally { setBusy(false); }
        }} />
        <PodcastLibrarySidebar feed={feed} showId={showId} shows={shows} subscriptions={player.state.subscriptions} busy={busy} onUnsubscribe={setUnsubscribeShow} downloadCount={downloads.length} queueCount={player.state.queue.length} onSelect={selectFeed} discoverActive={searchScope === "discover"} onDiscover={() => { setPreviewShowId(null); setFeed("recent"); setSearchQuery(""); setSearchScope("discover"); setError(null); }} />
      </div>
    </div>
  );
}
