"use client";

import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import {
  FEED_POST_BOOTSTRAP_REFRESH_MS,
  FEED_PROACTIVE_REFRESH_INTERVAL_MS,
  refreshPublicationFeedFirstPage,
} from "@/lib/feedRefresh";

/**
 * Polls and refocus-refreshes the active publication feed while the tab is visible.
 */
export function useProactiveFeedRefresh(
  publicationKey: string | null,
  articleFilter: ArticleListFilter = "all",
  enabled = true
) {
  const queryClient = useQueryClient();
  const { session, getOAuthSession } = useAuth();

  useEffect(() => {
    if (!enabled || !publicationKey || !session) return;

    let cancelled = false;

    const refresh = async () => {
      if (cancelled || document.visibilityState !== "visible") return;
      const oauth = getOAuthSession();
      if (!oauth) return;
      try {
        await refreshPublicationFeedFirstPage({
          queryClient,
          publicationKey,
          articleFilter,
          oauthSession: oauth,
          viewerDid: session.did,
          skipEnroll: true,
        });
      } catch {
        /* best-effort background refresh */
      }
    };

    const interval = window.setInterval(() => {
      void refresh();
    }, FEED_PROACTIVE_REFRESH_INTERVAL_MS);

    const onVisible = () => {
      if (document.visibilityState !== "visible") return;
      void refresh();
    };

    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
    };
  }, [
    enabled,
    publicationKey,
    articleFilter,
    session,
    getOAuthSession,
    queryClient,
  ]);
}

const pendingBootstrapRefreshes = new WeakMap<
  ReturnType<typeof useQueryClient>, Set<string>
>();

/** Coalesces the empty-page and done events into one background refresh. */
export function queueBootstrapFeedRefresh(args: {
  queryClient: ReturnType<typeof useQueryClient>;
  publicationKey: string;
  oauthSession: import("@atproto/oauth-client-browser").OAuthSession;
  viewerDid: string;
}) {
  const { queryClient, oauthSession, viewerDid } = args;
  const publicationKey = normalizeAtRepoParam(args.publicationKey);
  const key = JSON.stringify([viewerDid, publicationKey]);
  let pending = pendingBootstrapRefreshes.get(queryClient);
  if (!pending) {
    pending = new Set();
    pendingBootstrapRefreshes.set(queryClient, pending);
  }
  if (pending.has(key)) return;
  pending.add(key);
  window.setTimeout(() => {
    void refreshPublicationFeedFirstPage({
      queryClient,
      publicationKey,
      oauthSession,
      viewerDid,
      skipEnroll: false,
      allowCacheMiss: true,
    }).catch(() => {
      // Keep prior data; the normal feed query still exposes its own failures.
    }).finally(() => {
      pending.delete(key);
    });
  }, FEED_POST_BOOTSTRAP_REFRESH_MS);
}
