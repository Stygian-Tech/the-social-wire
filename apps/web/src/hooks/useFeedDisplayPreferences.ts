"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";

import {
  ACCOUNT_PREFERENCES_QUERY_KEY,
  useAccountPreferences,
} from "@/hooks/useReadLaterPreferences";
import { usePDSClient } from "@/hooks/usePDSClient";
import { useAuth } from "@/hooks/useAuth";
import type { PreferencesRecord, RepoRecord } from "@/lib/pdsClient";
import { isDummyReaderDataEnabled } from "@/lib/dummyReaderData";
import {
  DEFAULT_FEED_DISPLAY_PREFERENCES,
  TOP_LEVEL_FEEDS,
  loadCachedFeedDisplayPreferences,
  normalizeFeedDisplayPreferences,
  saveCachedFeedDisplayPreferences,
  type FeedDisplayPreferences,
  type TopLevelFeed,
} from "@/lib/feedPreferences";

export function useFeedDisplayPreferences() {
  const { session } = useAuth();
  const client = usePDSClient();
  const queryClient = useQueryClient();
  const accountPreferences = useAccountPreferences();
  const [optimistic, setOptimistic] =
    useState<FeedDisplayPreferences | null>(null);
  const [cached, setCached] = useState<FeedDisplayPreferences | null>(null);

  useEffect(() => {
    let cancelled = false;
    queueMicrotask(() => {
      if (cancelled) return;
      setCached(
        session && typeof window !== "undefined"
          ? loadCachedFeedDisplayPreferences(window.localStorage, session.did)
          : null,
      );
    });
    return () => {
      cancelled = true;
    };
  }, [session]);

  const serverPreferences = accountPreferences.data?.value;
  const preferences = useMemo(
    () =>
      optimistic ??
      (serverPreferences
        ? normalizeFeedDisplayPreferences(serverPreferences)
        : (cached ?? DEFAULT_FEED_DISPLAY_PREFERENCES)),
    [cached, optimistic, serverPreferences],
  );

  useEffect(() => {
    if (!session || !serverPreferences || typeof window === "undefined") return;
    const normalized = normalizeFeedDisplayPreferences(serverPreferences);
    saveCachedFeedDisplayPreferences(
      window.localStorage,
      session.did,
      normalized,
    );
  }, [serverPreferences, session]);

  const mutation = useMutation({
    mutationFn: async (next: FeedDisplayPreferences) => {
      if (isDummyReaderDataEnabled()) return next;
      if (!client) throw new Error("PDS session required");
      const existing = accountPreferences.data ?? null;
      await client.upsertPreferences(
        {
          visibleFeeds: next.visibleFeeds,
          feedsWithUnreadCounts: next.feedsWithUnreadCounts,
          rssArticleOpenMode: next.rssArticleOpenMode,
          showTopLevelFeedUnreadCounts:
            next.feedsWithUnreadCounts.length > 0,
        },
        existing,
      );
      return next;
    },
    onMutate: async (next) => {
      const normalized = normalizeFeedDisplayPreferences(next);
      setOptimistic(normalized);
      setCached(normalized);
      if (session && typeof window !== "undefined") {
        saveCachedFeedDisplayPreferences(
          window.localStorage,
          session.did,
          normalized,
        );
      }
      queryClient.setQueryData<RepoRecord<PreferencesRecord> | null>(
        ACCOUNT_PREFERENCES_QUERY_KEY,
        (previous) => ({
          uri:
            previous?.uri ??
            `at://${session?.did ?? ""}/app.thesocialwire.preferences/self`,
          cid: previous?.cid ?? "",
          value: {
            $type: "app.thesocialwire.preferences",
            createdAt: previous?.value.createdAt ?? new Date().toISOString(),
            updatedAt: new Date().toISOString(),
            ...previous?.value,
            visibleFeeds: normalized.visibleFeeds,
            feedsWithUnreadCounts: normalized.feedsWithUnreadCounts,
            rssArticleOpenMode: normalized.rssArticleOpenMode,
            showTopLevelFeedUnreadCounts:
              normalized.feedsWithUnreadCounts.length > 0,
          },
        }),
      );
    },
    onSuccess: () => {
      setOptimistic(null);
    },
    onError: () => {
      setOptimistic(null);
      void queryClient.invalidateQueries({
        queryKey: ACCOUNT_PREFERENCES_QUERY_KEY,
      });
    },
  });

  const setFeedVisible = useCallback(
    (feed: TopLevelFeed, visible: boolean) => {
      const visibleFeeds = visible
        ? TOP_LEVEL_FEEDS.filter(
            (candidate) =>
              candidate === feed || preferences.visibleFeeds.includes(candidate),
          )
        : preferences.visibleFeeds.filter((candidate) => candidate !== feed);
      if (visibleFeeds.length === 0) return;
      mutation.mutate({
        ...preferences,
        visibleFeeds,
        feedsWithUnreadCounts: visible
          ? preferences.feedsWithUnreadCounts
          : preferences.feedsWithUnreadCounts.filter(
              (candidate) => candidate !== feed,
            ),
      });
    },
    [mutation, preferences],
  );

  const setFeedUnreadCountVisible = useCallback(
    (feed: TopLevelFeed, show: boolean) => {
      if (!preferences.visibleFeeds.includes(feed)) return;
      const feedsWithUnreadCounts = show
        ? TOP_LEVEL_FEEDS.filter(
            (candidate) =>
              candidate === feed ||
              preferences.feedsWithUnreadCounts.includes(candidate),
          )
        : preferences.feedsWithUnreadCounts.filter(
            (candidate) => candidate !== feed,
          );
      mutation.mutate({
        ...preferences,
        feedsWithUnreadCounts,
      });
    },
    [mutation, preferences],
  );

  const setRssArticleOpenInReader = useCallback(
    (openInReader: boolean) => {
      mutation.mutate({
        ...preferences,
        rssArticleOpenMode: openInReader ? "reader" : "original",
      });
    },
    [mutation, preferences],
  );

  return {
    preferences,
    setFeedVisible,
    setFeedUnreadCountVisible,
    setRssArticleOpenInReader,
    isPending: mutation.isPending,
    error: mutation.error,
  };
}
