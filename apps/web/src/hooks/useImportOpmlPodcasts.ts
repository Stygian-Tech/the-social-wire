"use client";
import { useLayoutEffect, useRef } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "./useAuth";
import { notifyPodcastSubscriptionsChanged } from "@/lib/podcasts/subscriptionsChanged";
import { importOpmlPodcasts } from "@/lib/podcasts/opmlImport";
import { podcastRequest, writePodcastSubscription, type PodcastShow } from "@/lib/podcasts/client";
import type { ParsedOpmlFeed, OpmlImportProgress } from "@/lib/opmlImport";

export function useImportOpmlPodcasts(enabled: boolean) {
  const { session, getOAuthSession } = useAuth();
  const viewer = session?.did ?? null;
  const activeViewer = useRef(viewer);
  useLayoutEffect(() => {
    activeViewer.current = viewer;
    return () => { activeViewer.current = null; };
  }, [viewer]);
  const cache = useQueryClient();
  const queryKey = ["opmlPodcastShows", viewer];
  const existing = useQuery({
    queryKey,
    enabled: enabled && !!viewer,
    queryFn: async () => {
      const oauth = getOAuthSession();
      if (!oauth || oauth.did !== viewer) throw new Error("Sign In To Import Podcasts");
      return (await podcastRequest<{ shows: PodcastShow[] }>(oauth, "shows")).shows;
    },
  });
  const importer = useMutation({
    mutationFn: async (input: { feeds: readonly ParsedOpmlFeed[]; privateFeeds: boolean; onProgress: (progress: OpmlImportProgress) => void }) => {
      const oauth = getOAuthSession();
      const assertViewer = () => {
        if (!viewer || !oauth || oauth.did !== viewer || activeViewer.current !== viewer || getOAuthSession()?.did !== viewer) {
          throw new Error("Account Changed. Reopen The Importer Before Continuing.");
        }
      };
      assertViewer();
      const current = await podcastRequest<{ shows: PodcastShow[] }>(oauth!, "shows");
      assertViewer();
      try {
        return await importOpmlPodcasts({
          ...input,
          existingShows: current.shows,
          assertViewer,
          resolve: async (url, privateFeed) => {
            assertViewer();
            const response = await podcastRequest<{ show?: PodcastShow; shows?: PodcastShow[] }>(oauth!, privateFeed ? "private/resolve" : "resolve", "POST", { url });
            const show = response.show ?? response.shows?.[0];
            if (!show) throw new Error("No Audio Podcast Found");
            return show;
          },
          subscribe: async (show) => {
            assertViewer();
            await writePodcastSubscription(oauth!, viewer!, show);
          },
        });
      } finally {
        if (viewer && activeViewer.current === viewer && getOAuthSession()?.did === viewer)
          notifyPodcastSubscriptionsChanged(viewer);
      }
    },
    onSettled: () => {
      void cache.invalidateQueries({ queryKey });
      void cache.invalidateQueries({ queryKey: ["skyreaderFeedSubscriptions"] });
    },
  });
  return { existing, importer };
}
