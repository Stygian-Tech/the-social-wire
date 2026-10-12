"use client";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialWorkspaceSession } from "@/hooks/useSocialWorkspace";
import { changeSocialSavedFeed, getSocialFeedDirectory, getSocialSavedGenerators, type SavedFeedAction } from "@/lib/socialFeedDirectoryClient";
export function useSocialFeedDirectory(query: string) {
  const { did, sequence, requireSession } = useSocialWorkspaceSession();
  const catalog = useBlueskySocialCatalog();
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === did ? catalog.data.moderation : undefined;
  const labelers = moderation?.prefs.labelers.map(item => item.did) ?? [];
  const cache = useQueryClient();
  const directory = useInfiniteQuery({ queryKey: ["blueskySocial", did, "feedDirectory", query, sequence, labelers], enabled: !!did && !!moderation, initialPageParam: undefined as string | undefined, queryFn: ({ pageParam, signal }) => getSocialFeedDirectory(requireSession(), query, pageParam, signal, moderation), getNextPageParam: (last, all) => last.cursor && !all.slice(0, -1).some(page => page.cursor === last.cursor) ? last.cursor : undefined, retry: false });
  const saved = useQuery({ queryKey: ["blueskySocial", did, "savedGenerators", sequence, labelers], enabled: !!did, queryFn: ({ signal }) => getSocialSavedGenerators(requireSession(), signal), retry: false });
  const mutation = useMutation({ mutationFn: ({ uri, action }: { uri: string; action: SavedFeedAction }) => changeSocialSavedFeed(requireSession(), uri, action), onMutate: () => ({ did }), onSuccess: async (_result, _input, context) => { await Promise.all([cache.invalidateQueries({ queryKey: ["blueskySocial", context.did, "catalog"] }), cache.invalidateQueries({ queryKey: ["blueskySocial", context.did, "savedGenerators"] })]); } });
  return { directory, saved, mutation };
}
