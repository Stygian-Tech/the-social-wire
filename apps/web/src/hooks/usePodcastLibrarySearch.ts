"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { podcastRequest, type PodcastEpisode, type PodcastShow } from "@/lib/podcasts/client";

export type PodcastDirectoryCandidate = { provider: "podcastindex"; id: string; title: string; description?: string; artworkUrl?: string; feedUrl: string };
export type PodcastSearchPage = { shows: PodcastShow[]; episodes: PodcastEpisode[]; candidates?: PodcastDirectoryCandidate[]; directoryLimit?: number; cursor?: string; hasMore: boolean };
const searchableText = (text: string) => text.normalize("NFD").replace(/\p{M}/gu, "").toLocaleLowerCase();
const emptyPage: PodcastSearchPage = { shows: [], episodes: [], hasMore: false };

/** Each query owns its request and page cursor; account/filter changes discard late replies. */
export function usePodcastLibrarySearch({ viewer, query, scope = "library", showId, downloaded, getOAuthSession }: {
  viewer: string | null;
  query: string;
  scope?: "library" | "directory";
  showId?: string;
  downloaded?: PodcastEpisode[];
  getOAuthSession: () => OAuthSession | null;
}) {
  const oauthGetter = useRef(getOAuthSession);
  useLayoutEffect(() => { oauthGetter.current = getOAuthSession; }, [getOAuthSession]);
  const normalized = query.trim();
  const identity = JSON.stringify([viewer, normalized, scope, showId, downloaded !== undefined]);
  const currentIdentity = useRef(identity);
  useLayoutEffect(() => { currentIdentity.current = identity; }, [identity]);
  const [result, setResult] = useState<{ identity: string; page: PodcastSearchPage }>({ identity, page: emptyPage });
  const [loadingIdentity, setLoadingIdentity] = useState<string | null>(null);
  const [failure, setFailure] = useState<{ identity: string; message: string } | null>(null);
  const [attempt, setAttempt] = useState(0);
  const controller = useRef<AbortController | null>(null);
  const page = result.identity === identity ? result.page : emptyPage;
  const valid = normalized.length >= 2 && normalized.length <= 200;

  useEffect(() => {
    controller.current?.abort();
    if (!viewer || !valid) return;
    if (scope === "library" && downloaded !== undefined) return;
    const active = new AbortController();
    controller.current = active;
    const timer = setTimeout(() => {
      setLoadingIdentity(identity);
      setFailure(null);
      const oauth = oauthGetter.current();
      const request = oauth?.did === viewer && navigator.onLine
        ? podcastRequest<PodcastSearchPage>(oauth, "search", "POST", scope === "directory" ? { query: normalized, scope, limit: 50 } : { query: normalized, scope, kind: "all", showId, limit: 20 }, active.signal)
        : Promise.reject(new Error(navigator.onLine ? "Account Is Loading. Please Retry Search." : "Search Downloaded Episodes While Offline"));
      void request.then(next => {
        if (!active.signal.aborted && currentIdentity.current === identity) setResult({ identity, page: next });
      }).catch(error => {
        if (!active.signal.aborted && currentIdentity.current === identity) setFailure({ identity, message: error instanceof Error ? error.message : "Search Could Not Load. Please Retry." });
      }).finally(() => {
        if (!active.signal.aborted && currentIdentity.current === identity) setLoadingIdentity(null);
      });
    }, 250);
    return () => { clearTimeout(timer); active.abort(); controller.current?.abort(); };
  }, [identity, viewer, valid, normalized, scope, showId, downloaded, attempt]);

  async function loadMore() {
    if (scope === "directory" || !page.hasMore || !page.cursor || loadingIdentity === identity || downloaded !== undefined) return;
    const oauth = oauthGetter.current();
    if (!oauth || oauth.did !== viewer) { setFailure({ identity, message: "Account Is Loading. Please Retry Search." }); return; }
    const active = new AbortController();
    controller.current?.abort();
    controller.current = active;
    setLoadingIdentity(identity);
    setFailure(null);
    try {
      const next = await podcastRequest<PodcastSearchPage>(oauth, "search", "POST", { query: normalized, scope: "library", kind: "all", showId, limit: 20, cursor: page.cursor }, active.signal);
      if (active.signal.aborted || currentIdentity.current !== identity) return;
      setResult(previous => ({ identity, page: {
        ...next,
        shows: [...previous.page.shows, ...next.shows.filter(item => !previous.page.shows.some(existing => existing.id === item.id))],
        episodes: [...previous.page.episodes, ...next.episodes.filter(item => !previous.page.episodes.some(existing => existing.id === item.id))],
      } }));
    } catch (error) {
      if (!active.signal.aborted && currentIdentity.current === identity) setFailure({ identity, message: error instanceof Error ? error.message : "Search Could Not Load. Please Retry." });
    } finally {
      if (!active.signal.aborted && currentIdentity.current === identity) setLoadingIdentity(null);
    }
  }
  const localEpisodes = useMemo(() => {
    if (scope !== "library" || !viewer || !valid || downloaded === undefined) return [];
    const terms = searchableText(normalized).split(/\s+/);
    return downloaded.filter(episode => {
      const text = searchableText([episode.title, episode.description, ...episode.chapters?.map(chapter => chapter.title) ?? []].filter(Boolean).join(" "));
      return terms.every(term => text.includes(term));
    });
  }, [scope, viewer, valid, downloaded, normalized]);
  return { ...(scope === "library" && downloaded !== undefined ? { ...emptyPage, episodes: localEpisodes } : page), loading: (scope === "directory" || downloaded === undefined) && valid && (loadingIdentity === identity || (result.identity !== identity && failure?.identity !== identity)), error: failure?.identity === identity ? failure.message : null, valid, loadMore, retry: () => setAttempt(value => value + 1) };
}
