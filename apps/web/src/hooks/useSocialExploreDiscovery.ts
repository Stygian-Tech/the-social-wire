"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import { useSocialWorkspaceSession } from "@/hooks/useSocialWorkspace";
import { getSocialRecommendedFeeds, getSocialTrendingTopics } from "@/lib/socialExploreDiscoveryClient";
import { changeSocialSavedFeed } from "@/lib/socialFeedDirectoryClient";

export function useSocialExploreDiscovery(moderation: ModerationOpts | undefined, enabled: boolean) {
  const { did, sequence, requireSession } = useSocialWorkspaceSession();
  const cache = useQueryClient();
  const topics = useQuery({ queryKey: ["blueskySocial", did, "trendingTopics", sequence], enabled: enabled && !!did, queryFn: ({ signal }) => getSocialTrendingTopics(signal), staleTime: 60_000, retry: false });
  const feeds = useQuery({ queryKey: ["blueskySocial", did, "recommendedFeeds", sequence, moderation?.prefs.labelers.map(labeler => labeler.did)], enabled: enabled && !!did && moderation?.userDid === did, queryFn: ({ signal }) => {
    if (!moderation || moderation.userDid !== did) throw new Error("Your account changed. Please reload this page.");
    return getSocialRecommendedFeeds(requireSession(), moderation, signal);
  }, staleTime: 60_000, retry: false });
  const save = useMutation({ mutationFn: (uri: string) => changeSocialSavedFeed(requireSession(), uri, "save"), onMutate: () => ({ did }), onSuccess: async (_result, _uri, context) => { await Promise.all([cache.invalidateQueries({ queryKey: ["blueskySocial", context.did, "catalog"] }), cache.invalidateQueries({ queryKey: ["blueskySocial", context.did, "savedGenerators"] })]); } });
  return { topics, feeds, save };
}
