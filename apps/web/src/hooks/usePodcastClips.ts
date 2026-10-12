"use client";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useAuth } from "./useAuth";
import { podcastRequest, type PodcastClip } from "@/lib/podcasts/client";

export function usePodcastClips(episodeId?: string) {
  const { session, getOAuthSession } = useAuth();
  const viewer = session?.did ?? null;
  const epoch = useRef(0);
  const [revision, setRevision] = useState(0);
  const active = useRef<AbortController | null>(null);
  const [state, setState] = useState<{ viewer: string | null; revision: number; clips: PodcastClip[]; error: string | null; loading: boolean }>({ viewer, revision, clips: [], error: null, loading: true });
  useLayoutEffect(() => {
    const invalidate = (event: Event) => {
      if (event.type === "storage" && (event as StorageEvent).key !== "@@atproto/oauth-client-browser(sub)") return;
      epoch.current += 1; active.current?.abort(); setRevision(epoch.current);
    };
    window.addEventListener("storage", invalidate); window.addEventListener("the-social-wire.oauth-viewer-changed", invalidate);
    return () => { window.removeEventListener("storage", invalidate); window.removeEventListener("the-social-wire.oauth-viewer-changed", invalidate); };
  }, []);
  const refreshRef = useRef<() => Promise<void>>(async () => {});
  useEffect(() => {
    const controller = new AbortController();
    active.current = controller;
    let pending = false;
    const refresh = async () => {
      const oauth = getOAuthSession();
      if (pending || !viewer || oauth?.did !== viewer || controller.signal.aborted) return;
      pending = true;
      try {
        const page = await podcastRequest<{ clips: PodcastClip[] }>(oauth, "clips", "GET", undefined, controller.signal);
        if (!controller.signal.aborted && epoch.current === revision && getOAuthSession()?.did === viewer)
          setState({ viewer, revision, clips: page.clips, error: null, loading: false });
      } catch {
        if (!controller.signal.aborted && epoch.current === revision && getOAuthSession()?.did === viewer)
          setState(previous => ({ ...previous, viewer, revision, clips: previous.viewer === viewer && previous.revision === revision ? previous.clips : [], error: "Clips Could Not Load. Retrying…", loading: false }));
      } finally { pending = false; }
    };
    refreshRef.current = refresh;
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => { controller.abort(); clearInterval(timer); };
  }, [viewer, getOAuthSession, revision]);
  const refresh = useCallback(() => refreshRef.current(), []);
  const matching = state.viewer === viewer && state.revision === revision;
  return { clips: matching ? state.clips.filter(clip => !episodeId || clip.episodeId === episodeId) : [],
    loading: matching ? state.loading : true, error: matching ? state.error : null, refresh };
}
