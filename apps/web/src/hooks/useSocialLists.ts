"use client";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialWorkspaceSession } from "@/hooks/useSocialWorkspace";
import { getSocialList, getSocialLists } from "@/lib/socialListsClient";
import type { OAuthSession } from "@atproto/oauth-client-browser";
export function useSocialLists(uri: string | null) {
  const { did, sequence, requireSession } = useSocialWorkspaceSession();
  const catalog = useBlueskySocialCatalog();
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === did ? catalog.data.moderation : undefined;
  const labelers = moderation?.prefs.labelers.map(item => item.did) ?? [];
  const cache = useQueryClient();
  const lists = useInfiniteQuery({ queryKey: ["blueskySocial", did, "lists", sequence, labelers], enabled: !!did && !!moderation, initialPageParam: undefined as string | undefined, queryFn: ({ pageParam, signal }) => getSocialLists(requireSession(), pageParam, signal, moderation), getNextPageParam: (last, all) => last.cursor && !all.slice(0, -1).some(page => page.cursor === last.cursor) ? last.cursor : undefined, retry: false });
  const detail = useInfiniteQuery({ queryKey: ["blueskySocial", did, "listDetail", uri, sequence, labelers], enabled: !!did && !!uri && !!moderation, initialPageParam: undefined as string | undefined, queryFn: ({ pageParam, signal }) => getSocialList(requireSession(), uri!, pageParam, signal, moderation), getNextPageParam: (last, all) => last.cursor && !all.slice(0, -1).some(page => page.cursor === last.cursor) ? last.cursor : undefined, retry: false });
  const mutation = useMutation({ mutationFn: (write: (session: OAuthSession) => Promise<unknown>) => write(requireSession()), onMutate: () => ({ did }), onSuccess: (_result, _write, context) => cache.invalidateQueries({ queryKey: ["blueskySocial", context.did] }) });
  return { did, lists, detail, mutation };
}
