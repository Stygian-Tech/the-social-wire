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
      if (!client) throw new Error("PDS session required");
      const existing = accountPreferences.data ?? null;
      await client.upsertPreferences(
        {
          visibleFeeds: next.visibleFeeds,
          showTopLevelFeedUnreadCounts:
            next.showTopLevelFeedUnreadCounts,
        },
        existing,
      );
      return next;
    },
    onMutate: async (next) => {
      const normalized = normalizeFeedDisplayPreferences(next);
      setOptimistic(normalized);
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
            showTopLevelFeedUnreadCounts:
              normalized.showTopLevelFeedUnreadCounts,
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
      });
    },
    [mutation, preferences],
  );

  const setShowTopLevelFeedUnreadCounts = useCallback(
    (show: boolean) => {
      mutation.mutate({
        ...preferences,
        showTopLevelFeedUnreadCounts: show,
      });
    },
    [mutation, preferences],
  );

  return {
    preferences,
    setFeedVisible,
    setShowTopLevelFeedUnreadCounts,
    isPending: mutation.isPending,
    error: mutation.error,
  };
}
