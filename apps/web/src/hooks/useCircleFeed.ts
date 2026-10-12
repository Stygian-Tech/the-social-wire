"use client";

import { isExpiredFeedCursor } from "@/lib/feedResponseError";
import { useExpiredFeedCursorRecovery } from "@/hooks/useExpiredFeedCursorRecovery";

import { useEffect, useMemo, useRef } from "react";
import { coalesceFeedFirstPage } from "@/lib/feedRefreshCoordinator";
import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import {
  getCircleCatalog,
  getCircleEdition,
  setCircleItemHidden,
} from "@/lib/circleFeedClient";
import { selectWireLanguage } from "@/lib/wireFeedClient";

export const CIRCLE_CATALOG_QUERY_KEY = (viewerDid: string) =>
  ["circleCatalog", viewerDid] as const;
export const CIRCLE_EDITION_QUERY_KEY = (
  viewerDid: string,
  language: string,
) => ["circleEdition", viewerDid, language] as const;

export const CIRCLE_STALE_TIME_MS = 10 * 60_000;

export function useCircleCatalog() {
  const { session, isLoading, getOAuthSession, oauthSessionReloadSeq } =
    useAuth();
  const viewerDid = session?.did ?? "signed-out";
  const oauthSession = getOAuthSession();

  return useQuery({
    queryKey: [
      ...CIRCLE_CATALOG_QUERY_KEY(viewerDid),
      oauthSessionReloadSeq,
    ],
    queryFn: ({ signal }) => {
      if (!oauthSession) throw new Error("Your Circle requires sign-in.");
      return getCircleCatalog({ oauthSession, signal });
    },
    enabled: !isLoading && Boolean(session && oauthSession),
    staleTime: 5 * 60_000,
    retry: (count, error) => !isExpiredFeedCursor(error) && count < 1,
  });
}

export function useCircleEdition(args: { enabled: boolean }) {
  const { session, isLoading, getOAuthSession, oauthSessionReloadSeq } =
    useAuth();
  const catalog = useCircleCatalog();
  const queryClient = useQueryClient();
  const viewerDid = session?.did ?? "signed-out";
  const oauthSession = getOAuthSession();
  const language = useMemo(
    () => selectWireLanguage(catalog.data?.supportedLanguages ?? []),
    [catalog.data?.supportedLanguages],
  );
  const languageKey = language ?? "default";

  const queryKey = useMemo(() => [...CIRCLE_EDITION_QUERY_KEY(viewerDid, languageKey), oauthSessionReloadSeq], [viewerDid, languageKey, oauthSessionReloadSeq]);
  const query = useInfiniteQuery({
    queryKey,
    queryFn: ({ pageParam, signal }) => {
      if (!oauthSession) throw new Error("Your Circle requires sign-in.");
      const fetchPage = () => getCircleEdition({ oauthSession, language, cursor: pageParam, signal });
      return pageParam ? fetchPage() : coalesceFeedFirstPage(queryClient, oauthSession, queryKey, fetchPage);
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.moreCursor,
    enabled:
      args.enabled &&
      !isLoading &&
      Boolean(session && oauthSession) &&
      catalog.data?.enabled === true &&
      catalog.data.available === true,
    staleTime: CIRCLE_STALE_TIME_MS,
    refetchOnWindowFocus: false,
    refetchOnMount: false,
    retry: (count, error) => !isExpiredFeedCursor(error) && count < 1,
  });

  const refreshGeneration = useMutation({
    mutationKey: ["refreshCircleEdition", viewerDid, languageKey, oauthSessionReloadSeq],
    onMutate: () => ({
      queryKey: [...CIRCLE_EDITION_QUERY_KEY(viewerDid, languageKey), oauthSessionReloadSeq],
      oauthSession,
    }),
    mutationFn: async () => {
      if (!oauthSession) throw new Error("Your Circle requires sign-in.");
      return coalesceFeedFirstPage(queryClient, oauthSession, queryKey, () => getCircleEdition({ oauthSession, language, bypassCache: true }));
    },
    onSuccess: async (fresh, _variables, context) => {
      // Mutation completion can outlive an account switch or sign-out. Only the
      // session that started this request may publish its private generation.
      if (!context || getOAuthSession() !== context.oauthSession) return;
      await queryClient.cancelQueries({ queryKey: context.queryKey, exact: true });
      if (getOAuthSession() !== context.oauthSession) return;
      queryClient.setQueryData(context.queryKey, { pages: [fresh], pageParams: [undefined] });
    },
  });
  const restoredContext = useRef<string | null>(null);
  useEffect(() => {
    const context = JSON.stringify(queryKey);
    if (!args.enabled || !query.isSuccess || query.isFetchedAfterMount || restoredContext.current === context || Date.now() - (queryClient.getQueryState(queryKey)?.dataUpdatedAt ?? 0) < CIRCLE_STALE_TIME_MS) return;
    restoredContext.current = context;
    void refreshGeneration.mutateAsync().catch(() => {});
  }, [args.enabled, query.isSuccess, query.isFetchedAfterMount, queryKey, queryClient, refreshGeneration]);
  useEffect(() => {
    if (!args.enabled || !query.isSuccess) return;
    const refreshVisible = () => {
      if (document.visibilityState === "visible" && Date.now() - (queryClient.getQueryState(queryKey)?.dataUpdatedAt ?? 0) >= CIRCLE_STALE_TIME_MS) void refreshGeneration.mutateAsync().catch(() => {});
    };
    window.addEventListener("focus", refreshVisible);
    document.addEventListener("visibilitychange", refreshVisible);
    return () => { window.removeEventListener("focus", refreshVisible); document.removeEventListener("visibilitychange", refreshVisible); };
  }, [args.enabled, query.isSuccess, queryClient, queryKey, refreshGeneration]);
  useExpiredFeedCursorRecovery(query.error, refreshGeneration.mutateAsync, args.enabled);
  return {
    ...query, refetch: refreshGeneration.mutateAsync, isFetching: query.isFetching || refreshGeneration.isPending, catalog, language,
    error: refreshGeneration.error ?? query.error,
    isError: refreshGeneration.isError || query.isError,
  };
}

export function useSetCircleItemHidden() {
  const { session, getOAuthSession } = useAuth();
  const queryClient = useQueryClient();
  const viewerDid = session?.did;

  return useMutation({
    mutationKey: ["setCircleItemHidden", viewerDid ?? "signed-out"],
    mutationFn: async ({
      storyId,
      hidden,
    }: {
      storyId: string;
      hidden: boolean;
    }) => {
      const oauthSession = getOAuthSession();
      if (!oauthSession || !viewerDid) {
        throw new Error("Your Circle requires sign-in.");
      }
      return setCircleItemHidden({ oauthSession, storyId, hidden });
    },
    onSuccess: async (state) => {
      if (!viewerDid || state.hidden) return;
      await queryClient.invalidateQueries({
        queryKey: ["circleEdition", viewerDid],
      });
    },
  });
}
