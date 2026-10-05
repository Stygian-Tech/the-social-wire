"use client";
import { PodcastSelect } from "./PodcastSelect";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import Link from "next/link";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { usePodcastViewer } from "@/hooks/usePodcastViewer";
import { useAuth } from "@/hooks/useAuth";
import {
  initialPodcastState,
  podcastMediaPath,
  podcastRequest,
  PodcastRevisionConflict,
  type PodcastEpisode,
  type PodcastState,
  type PodcastStateEnvelope,
  type PodcastSilence,
} from "@/lib/podcasts/client";
import { mergePodcastPatch } from "@/lib/podcasts/state";
import {
  getPodcastDownload,
  savePodcastDownload,
  registerPodcastOfflineShell,
} from "@/lib/podcasts/offline";
import {
  clampPlaybackTime,
  formatPodcastTime,
  PODCAST_SPEEDS,
  podcastsEnabled,
  silenceSkipTarget,
} from "@/lib/podcasts/playback";

type StatePatch = Partial<PodcastState>;
type PlayerContext = {
  episode: PodcastEpisode | null;
  playing: boolean;
  position: number;
  duration: number;
  state: PodcastState;
  error: string | null;
  silence: PodcastSilence | null;
  play: (episode: PodcastEpisode) => Promise<void>;
  toggle: () => void;
  seek: (time: number) => void;
  changeState: (patch: StatePatch) => Promise<void>;
  setRemoveSilences: (enabled: boolean) => Promise<void>;
  clearError: () => void;
};
const Context = createContext<PlayerContext | null>(null);
const cacheKey = (did: string) => `the-social-wire.podcast-state.v1:${did}`;
export function PodcastPlayerProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const { getOAuthSession } = useAuth();
  const viewer = usePodcastViewer() ?? undefined;
  const audio = useRef<HTMLAudioElement | null>(null);
  const active = useRef<PodcastEpisode | null>(null);
  const playbackGeneration = useRef(0);
  const objectUrl = useRef<string | null>(null);
  const stateRef = useRef(initialPodcastState());
  const pending = useRef<StatePatch>({});
  const synchronization = useRef(Promise.resolve());
  const viewerRef = useRef(viewer);
  const [episode, setEpisode] = useState<PodcastEpisode | null>(null);
  const [state, setState] = useState(initialPodcastState);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [silence, setSilence] = useState<PodcastSilence | null>(null);
  const silenceRef = useRef<PodcastSilence | null>(null);
  const persist = useCallback(() => {
    if (!viewerRef.current) return;
    try {
      localStorage.setItem(
        cacheKey(viewerRef.current),
        JSON.stringify({
          state: stateRef.current,
          pending: pending.current,
          episode: active.current,
        }),
      );
    } catch {
      setError(
        "Listening state could not be saved on this device. Check browser storage.",
      );
    }
  }, []);
  const sync = useCallback(async () => {
    const oauth = getOAuthSession();
    const did = viewerRef.current;
    if (!oauth || !did || !navigator.onLine) return;
    const patches = pending.current;
    if (!Object.keys(patches).length) return;
    for (let attempt = 0; attempt < 3; attempt++) {
      const current = await podcastRequest<PodcastStateEnvelope>(
        oauth,
        "state",
      );
      if (viewerRef.current !== did) return;
      try {
        const updated = await podcastRequest<PodcastStateEnvelope>(
          oauth,
          "state",
          "PUT",
          {
            expectedRevision: current.revision,
            state: mergePodcastPatch(current.state, patches),
          },
        );
        if (viewerRef.current !== did) return;
        // New edits made while the request was in flight remain pending.
        const remainder = { ...pending.current };
        for (const field of Object.keys(patches) as (keyof StatePatch)[])
          if (remainder[field] === patches[field]) delete remainder[field];
        pending.current = remainder;
        stateRef.current = mergePodcastPatch(updated.state, remainder);
        setState(stateRef.current);
        persist();
        return;
      } catch (reason) {
        if (!(reason instanceof PodcastRevisionConflict) || attempt === 2)
          throw reason;
      }
    }
  }, [getOAuthSession, persist]);
  const changeState = useCallback(
    async (patch: StatePatch) => {
      stateRef.current = mergePodcastPatch(stateRef.current, patch);
      setState(stateRef.current);
      pending.current = {
        ...pending.current,
        ...patch,
        ...(patch.progress
          ? { progress: { ...pending.current.progress, ...patch.progress } }
          : {}),
      };
      persist();
      synchronization.current = synchronization.current
        .catch(() => {})
        .then(sync)
        .catch((reason) => {
          setError(
            reason instanceof Error
              ? reason.message
              : "Listening sync failed. Your changes remain saved locally.",
          );
        });
      await synchronization.current;
    },
    [persist, sync],
  );
  const saveProgress = useCallback(() => {
    const item = active.current;
    const element = audio.current;
    if (!item || !element || !element.src || !viewerRef.current) return;
    void changeState({
      progress: {
        [item.id]: {
          positionSeconds: element.currentTime,
          completed:
            element.ended ||
            stateRef.current.progress[item.id]?.completed === true,
          updatedAt: new Date().toISOString(),
        },
      },
    });
  }, [changeState]);
  const seek = useCallback(
    (time: number) => {
      if (!audio.current) return;
      audio.current.currentTime = clampPlaybackTime(
        time,
        audio.current.duration || active.current?.durationSeconds || 0,
      );
      setPosition(audio.current.currentTime);
      saveProgress();
    },
    [saveProgress],
  );
  const play = useCallback(
    async (item: PodcastEpisode) => {
      const element = audio.current;
      if (!element || !viewerRef.current) return;
      const generation = ++playbackGeneration.current;
      const did = viewerRef.current;
      saveProgress();
      element.pause();
      if (objectUrl.current) URL.revokeObjectURL(objectUrl.current);
      objectUrl.current = null;
      let source = item.audioUrl;
      let localSource = false;
      try {
        const local = await getPodcastDownload(did, item.id);
        if (
          generation !== playbackGeneration.current ||
          viewerRef.current !== did
        )
          return;
        if (local?.media) {
          localSource = true;
          if (navigator.serviceWorker?.controller)
            source = `/podcasts/offline-media?viewer=${encodeURIComponent(viewerRef.current)}&episodeId=${encodeURIComponent(item.id)}`;
          else {
            objectUrl.current = URL.createObjectURL(local.media);
            source = objectUrl.current;
          }
        } else if (!navigator.onLine)
          throw new Error(
            "This episode is not downloaded or its file was evicted. Re-download when online.",
          );
      } catch (reason) {
        if (!navigator.onLine) {
          setError(String(reason));
          return;
        }
      }
      if (
        generation !== playbackGeneration.current ||
        viewerRef.current !== did
      )
        return;
      if (item.visibility === "private" && !localSource) {
        try {
          const oauth = getOAuthSession();
          if (!oauth) throw new Error("Sign In to Play This Private Episode");
          const response = await gatewayFetch(oauth, `/v1/podcasts/${podcastMediaPath(item.id)}`);
          if (!response.ok) throw new Error("Private Audio Could Not Be Loaded");
          const media = await response.blob();
          if (generation !== playbackGeneration.current || viewerRef.current !== did) return;
          if (!media.size) throw new Error("The Audio File Was Empty");
          objectUrl.current = URL.createObjectURL(media);
          source = objectUrl.current;
        } catch {
          setError("Private Audio Could Not Be Loaded. Try Downloading It for Offline Playback.");
          return;
        }
      }
      active.current = item;
      setEpisode(item);
      setSilence(null);
      silenceRef.current = null;
      element.src = source;
      element.playbackRate = stateRef.current.playbackSpeed;
      element.preservesPitch = true;
      const resume = stateRef.current.progress[item.id];
      element.onloadedmetadata = () => {
        element.currentTime = clampPlaybackTime(
          resume?.completed ? 0 : (resume?.positionSeconds ?? 0),
          element.duration,
        );
        setDuration(element.duration);
        setPosition(element.currentTime);
      };
      persist();
      try {
        await element.play();
      } catch (reason) {
        setError(
          reason instanceof Error ? reason.message : "Audio could not play",
        );
      }
      const oauth = getOAuthSession();
      if (oauth && item.visibility !== "private" && stateRef.current.removeSilences) {
        try {
          const local = await getPodcastDownload(viewerRef.current, item.id);
          const analysis =
            local?.silence ??
            (await podcastRequest<PodcastSilence>(
              oauth,
              `analysis?episodeId=${encodeURIComponent(item.id)}`,
            ));
          if (active.current?.id === item.id) {
            silenceRef.current = analysis;
            setSilence(analysis);
          }
        } catch {
          /* Playback continues while analysis is unavailable. */
        }
      }
    },
    [getOAuthSession, persist, saveProgress],
  );
  const toggle = useCallback(() => {
    const element = audio.current;
    if (!element) return;
    if (!element.src && active.current) {
      void play(active.current);
      return;
    }
    if (element.paused)
      void element.play().catch((reason) => setError(String(reason)));
    else element.pause();
  }, [play]);
  const setRemoveSilences = useCallback(
    async (enabled: boolean) => {
      await changeState({ removeSilences: enabled });
      const oauth = getOAuthSession();
      const item = active.current;
      if (!enabled || !item || !oauth) return;
      if (item.visibility === "private") {
        setSilence({ status: "unavailable", intervals: [] });
        return;
      }
      try {
        await podcastRequest(oauth, "analysis", "POST", { episodeId: item.id });
        const result = await podcastRequest<PodcastSilence>(
          oauth,
          `analysis?episodeId=${encodeURIComponent(item.id)}`,
        );
        if (active.current?.id === item.id) {
          silenceRef.current = result;
          setSilence(result);
          if (result.status === "complete" && viewerRef.current) {
            const local = await getPodcastDownload(viewerRef.current, item.id);
            if (local)
              await savePodcastDownload(
                viewerRef.current,
                { ...local, silence: result },
                local.media,
              );
          }
        }
      } catch (reason) {
        setError(String(reason));
      }
    },
    [changeState, getOAuthSession],
  );
  useEffect(() => {
    if (!podcastsEnabled()) return;
    const element = new Audio();
    audio.current = element;
    element.preload = "metadata";
    const onTime = () => {
      if (
        stateRef.current.removeSilences &&
        silenceRef.current?.status === "complete"
      ) {
        const target = silenceSkipTarget(
          element.currentTime,
          silenceRef.current.intervals,
          element.duration,
        );
        if (target !== null) element.currentTime = target;
      }
      setPosition(element.currentTime);
      if (
        "mediaSession" in navigator &&
        Number.isFinite(element.duration) &&
        element.duration > 0
      )
        navigator.mediaSession.setPositionState({
          duration: element.duration,
          position: clampPlaybackTime(element.currentTime, element.duration),
          playbackRate: element.playbackRate,
        });
    };
    const onPlay = () => {
      setPlaying(true);
      if ("mediaSession" in navigator)
        navigator.mediaSession.playbackState = "playing";
    };
    const onPause = () => {
      setPlaying(false);
      saveProgress();
      if ("mediaSession" in navigator)
        navigator.mediaSession.playbackState = "paused";
    };
    const onEnded = () => {
      saveProgress();
      const queue = stateRef.current.queue.filter(
        (id) => id !== active.current?.id,
      );
      void changeState({ queue });
      const oauth = getOAuthSession();
      if (queue[0] && viewerRef.current)
        void getPodcastDownload(viewerRef.current, queue[0])
          .then(async (local) => {
            if (local) return play(local.episode);
            if (oauth) {
              const page = await podcastRequest<{ episodes: PodcastEpisode[] }>(
                oauth,
                `episodes?episodeId=${encodeURIComponent(queue[0])}`,
              );
              if (page.episodes[0]) return play(page.episodes[0]);
            }
          })
          .catch((reason) => setError(String(reason)));
    };
    element.addEventListener("timeupdate", onTime);
    element.addEventListener("play", onPlay);
    element.addEventListener("pause", onPause);
    element.addEventListener("ended", onEnded);
    const onError = () =>
      setError(
        "Audio could not load. Try downloading it for offline playback.",
      );
    element.addEventListener("error", onError);
    const timer = setInterval(saveProgress, 15000);
    const offline = () => {
      void sync().catch((reason) => setError(String(reason)));
    };
    window.addEventListener("online", offline);
    window.addEventListener("pagehide", saveProgress);
    void registerPodcastOfflineShell().catch(() => {});
    return () => {
      clearInterval(timer);
      element.pause();
      element.src = "";
      audio.current = null;
      window.removeEventListener("online", offline);
      window.removeEventListener("pagehide", saveProgress);
      if (objectUrl.current) URL.revokeObjectURL(objectUrl.current);
    };
  }, [changeState, getOAuthSession, play, saveProgress, sync]);
  useEffect(() => {
    playbackGeneration.current++;
    active.current = null;
    audio.current?.pause();
    if (audio.current) audio.current.src = "";
    viewerRef.current = viewer;
    pending.current = {};
    stateRef.current = initialPodcastState();
    let cancelled = false;
    queueMicrotask(() => {
      if (!cancelled) {
        setState(stateRef.current);
        setEpisode(null);
        setPosition(0);
      }
    });
    if (viewer && podcastsEnabled()) {
      try {
        const raw = localStorage.getItem(cacheKey(viewer));
        if (raw) {
          const local = JSON.parse(raw);
          stateRef.current = { ...initialPodcastState(), ...local.state };
          pending.current = local.pending ?? {};
          active.current = local.episode ?? null;
          queueMicrotask(() => {
            if (!cancelled) {
              setState(stateRef.current);
              setEpisode(active.current);
            }
          });
        }
      } catch {
        /* Invalid private cache is replaced on synchronization. */
      }
      const oauth = getOAuthSession();
      if (oauth && navigator.onLine)
        void podcastRequest<PodcastStateEnvelope>(oauth, "state")
          .then((envelope) => {
            if (cancelled) return;
            stateRef.current = mergePodcastPatch(
              envelope.state,
              pending.current,
            );
            setState(stateRef.current);
            persist();
            return sync();
          })
          .catch((reason) => {
            if (!cancelled && navigator.onLine) setError(String(reason));
          });
    }
    return () => {
      cancelled = true;
    };
  }, [viewer, getOAuthSession, persist, sync]);
  useEffect(() => {
    if (audio.current) audio.current.playbackRate = state.playbackSpeed;
  }, [state.playbackSpeed]);
  useEffect(() => {
    if (!episode || !("mediaSession" in navigator)) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: episode.title,
      artist: "The Social Wire",
      ...(episode.artworkUrl ? { artwork: [{ src: episode.artworkUrl }] } : {}),
    });
    const handlers: Partial<
      Record<MediaSessionAction, MediaSessionActionHandler>
    > = {
      play: () => {
        if (audio.current?.paused) toggle();
      },
      pause: () => audio.current?.pause(),
      seekbackward: (details) =>
        seek((audio.current?.currentTime ?? 0) - (details.seekOffset ?? 15)),
      seekforward: (details) =>
        seek((audio.current?.currentTime ?? 0) + (details.seekOffset ?? 30)),
      seekto: (details) => {
        if (details.seekTime !== undefined) seek(details.seekTime);
      },
    };
    for (const [action, handler] of Object.entries(handlers)) {
      try {
        navigator.mediaSession.setActionHandler(
          action as MediaSessionAction,
          handler,
        );
      } catch {}
    }
    return () => {
      for (const action of Object.keys(handlers)) {
        try {
          navigator.mediaSession.setActionHandler(
            action as MediaSessionAction,
            null,
          );
        } catch {}
      }
    };
  }, [episode, seek, toggle]);
  useEffect(() => {
    if (!episode || episode.visibility === "private" || !state.removeSilences || silence?.status === "complete")
      return;
    const timer = setInterval(() => {
      const oauth = getOAuthSession();
      if (oauth)
        void podcastRequest<PodcastSilence>(
          oauth,
          `analysis?episodeId=${encodeURIComponent(episode.id)}`,
        )
          .then(async (result) => {
            silenceRef.current = result;
            setSilence(result);
            if (result.status === "complete" && viewerRef.current) {
              const local = await getPodcastDownload(
                viewerRef.current,
                episode.id,
              );
              if (local)
                await savePodcastDownload(
                  viewerRef.current,
                  { ...local, silence: result },
                  local.media,
                );
            }
          })
          .catch(() => {});
    }, 5000);
    return () => clearInterval(timer);
  }, [episode, state.removeSilences, silence?.status, getOAuthSession]);
  return (
    <Context.Provider
      value={{
        episode,
        playing,
        position,
        duration,
        state,
        error,
        silence,
        play,
        toggle,
        seek,
        changeState,
        setRemoveSilences,
        clearError: () => setError(null),
      }}
    >
      {children}
      {podcastsEnabled() && viewer && episode ? (
        <aside
          aria-label="Podcast Player"
          className="fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom))] z-50 border-t bg-background p-3 shadow-lg md:bottom-0"
        >
          <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-3">
            <Link
              href="/podcasts"
              className="min-w-0 flex-1 truncate text-sm font-semibold"
            >
              {episode.title}
            </Link>
            <button
              aria-label="Back 15 Seconds"
              onClick={() => seek(position - 15)}
              className="min-h-11 px-2"
            >
              −15
            </button>
            <button
              onClick={toggle}
              className="min-h-11 rounded bg-primary px-4 text-primary-foreground"
            >
              {playing ? "Pause" : "Play"}
            </button>
            <button
              aria-label="Forward 30 Seconds"
              onClick={() => seek(position + 30)}
              className="min-h-11 px-2"
            >
              +30
            </button>
            <label className="text-sm">
              Speed{" "}
              <PodcastSelect
                aria-label="Playback Speed"
                value={state.playbackSpeed}
                onChange={(event) =>
                  void changeState({
                    playbackSpeed: Number(event.target.value),
                  })
                }
                className="rounded border bg-background px-2 py-2"
              >
                {PODCAST_SPEEDS.map((speed) => (
                  <option key={speed} value={speed}>
                    {speed}×
                  </option>
                ))}
              </PodcastSelect>
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                disabled={episode.visibility === "private"}
                checked={episode.visibility === "private" ? false : state.removeSilences}
                onChange={(event) =>
                  void setRemoveSilences(event.target.checked)
                }
              />
              Remove Silences
            </label>
            <input
              aria-label="Seek Podcast"
              type="range"
              min={0}
              max={duration || episode.durationSeconds || 0}
              step={0.1}
              value={Math.min(
                position,
                duration || episode.durationSeconds || 0,
              )}
              onChange={(event) => seek(Number(event.target.value))}
              className="w-full"
            />
            <span className="text-xs tabular-nums">
              {formatPodcastTime(position)} /{" "}
              {formatPodcastTime(duration || episode.durationSeconds || 0)}
            </span>
            {episode.visibility !== "private" && state.removeSilences && silence?.status !== "complete" ? (
              <span className="text-xs" role="status">
                Silence Analysis: {silence?.status ?? "Pending"}
                {silence?.status === "failed" ||
                silence?.status === "unavailable" ? (
                  <button
                    className="ml-2 underline"
                    onClick={() => void setRemoveSilences(true)}
                  >
                    Retry Analysis
                  </button>
                ) : null}
              </span>
            ) : null}
            {error ? (
              <p role="alert" className="text-sm text-destructive">
                {error}
                <button
                  className="ml-2 underline"
                  onClick={() => setError(null)}
                >
                  Dismiss
                </button>
              </p>
            ) : null}
          </div>
        </aside>
      ) : null}
    </Context.Provider>
  );
}
export function usePodcastPlayer(): PlayerContext {
  const context = useContext(Context);
  if (!context) throw new Error("Podcast player provider is missing");
  return context;
}
