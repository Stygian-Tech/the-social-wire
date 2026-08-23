"use client";

import { useCallback, useEffect, useMemo, useRef } from "react";
import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
  type QueryClient,
} from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import { useWireFeedCatalog } from "@/hooks/useWireFeed";
import { WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";
import { isDummyReaderDataEnabled } from "@/lib/dummyReaderData";
import {
  getWireEdition,
  type WireEditionPage,
} from "@/lib/wireEditionClient";
import {
  createWireModerationDpopProofPool,
  getWire,
  selectWireLanguage,
  selectWireViewerRegion,
  wirePageToEntriesPage,
} from "@/lib/wireFeedClient";

export const WIRE_EDITION_QUERY_KEY = (
  language: string,
  region: string,
  modeKey: string,
) => ["wireEdition", language, region, modeKey] as const;

export const WIRE_EDITION_REFRESH_INTERVAL_MS = 5 * 60_000;
export const WIRE_EDITION_REFRESH_POLICY = {
  staleTime: WIRE_EDITION_REFRESH_INTERVAL_MS,
  refetchInterval: WIRE_EDITION_REFRESH_INTERVAL_MS,
  refetchIntervalInBackground: false,
  refetchOnMount: "always" as const,
  refetchOnWindowFocus: false,
};

const WIRE_MODERATION_SESSION_ERROR = new Error(
  "Your moderation settings could not be applied to The Wire; retry.",
);

function hasModerationScopes(scope: unknown): boolean {
  const granted = new Set(
    String(scope ?? "")
      .split(/\s+/)
      .filter(Boolean),
  );
  return WIRE_MODERATION_RPC_SCOPES.every((required) => granted.has(required));
}

export function replaceWireEditionQueryGeneration(
  queryClient: QueryClient,
  languageKey: string,
  regionKey: string,
  modeKey: string,
  fresh: WireEditionPage,
): void {
  queryClient.setQueryData<
    InfiniteData<WireEditionPage, string | undefined>
  >(WIRE_EDITION_QUERY_KEY(languageKey, regionKey, modeKey), {
    pages: [fresh],
    pageParams: [undefined],
  });
}

export function useWireEdition(args: {
  enabled: boolean;
  refreshCachedOnMount?: boolean;
}) {
  const catalog = useWireFeedCatalog();
  const {
    session,
    isLoading: authLoading,
    getOAuthSession,
    oauthSessionReloadSeq,
  } = useAuth();
  const queryClient = useQueryClient();
  const localPreview = isDummyReaderDataEnabled();
  const language = useMemo(
    () => selectWireLanguage(catalog.data?.supportedLanguages ?? []),
    [catalog.data?.supportedLanguages],
  );
  const languageKey = language ?? "default";
  const region = useMemo(() => selectWireViewerRegion(), []);
  const regionKey = region ?? "default";
  const oauthSession = getOAuthSession();
  const moderationCapability = useQuery({
    queryKey: [
      "wireModerationCapability",
      session?.did ?? "public",
      oauthSessionReloadSeq,
    ],
    queryFn: async () => {
      if (!oauthSession) return false;
      const info = await oauthSession.getTokenInfo("auto");
      return hasModerationScopes(info.scope);
    },
    enabled: args.enabled && Boolean(session && oauthSession),
    staleTime: Number.POSITIVE_INFINITY,
    gcTime: 60 * 60_000,
    retry: false,
    refetchOnWindowFocus: false,
  });
  const moderationCheckPending =
    authLoading ||
    (Boolean(session && oauthSession) && moderationCapability.isPending);
  const moderationSessionUnavailable =
    Boolean(session) && !authLoading && !oauthSession && !localPreview;
  const viewerModerationCapable = moderationCapability.data === true;
  const viewerModerationNeedsReauth =
    Boolean(session && oauthSession) && moderationCapability.data === false;
  const moderationModeKey =
    moderationCheckPending ||
    moderationSessionUnavailable ||
    moderationCapability.isError
      ? `checking:${session?.did ?? "public"}`
      : viewerModerationCapable
        ? `viewer:${session?.did ?? "unknown"}`
        : "baseline";
  const modeKey = moderationModeKey;
  const queryKey = WIRE_EDITION_QUERY_KEY(languageKey, regionKey, modeKey);
  const refreshKeyRef = useRef<string | null>(null);

  const requireModerationReady = useCallback(() => {
    if (
      moderationCheckPending ||
      moderationSessionUnavailable ||
      moderationCapability.isError
    ) {
      throw moderationCapability.error instanceof Error
        ? moderationCapability.error
        : WIRE_MODERATION_SESSION_ERROR;
    }
  }, [
    moderationCapability.error,
    moderationCapability.isError,
    moderationCheckPending,
    moderationSessionUnavailable,
  ]);

  const fetchEditionPage = useCallback(
    async (signal?: AbortSignal) => {
      requireModerationReady();
      if (!viewerModerationCapable) {
        return getWireEdition({ language, region, signal });
      }
      if (!oauthSession) throw WIRE_MODERATION_SESSION_ERROR;
      const moderationDpopProofPool =
        await createWireModerationDpopProofPool(oauthSession);
      return getWireEdition({
        language,
        region,
        signal,
        oauthSession,
        moderationDpopProofPool,
      });
    },
    [
      language,
      region,
      oauthSession,
      requireModerationReady,
      viewerModerationCapable,
    ],
  );

  const query = useInfiniteQuery({
    queryKey,
    queryFn: ({ signal }) => fetchEditionPage(signal),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: () => undefined,
    enabled:
      args.enabled &&
      !moderationCheckPending &&
      !moderationSessionUnavailable &&
      !moderationCapability.isError &&
      catalog.data?.enabled === true &&
      catalog.data.available === true,
    ...WIRE_EDITION_REFRESH_POLICY,
    gcTime: 7 * 24 * 60 * 60_000,
    retry: 1,
  });

  const firstEdition = query.data?.pages[0];
  const initialMoreCursor = firstEdition?.moreCursor;
  const fetchMorePage = useCallback(
    async (cursor: string, signal?: AbortSignal) => {
      requireModerationReady();
      if (!viewerModerationCapable) {
        return wirePageToEntriesPage(
          await getWire({ cursor, language, signal }),
        );
      }
      if (!oauthSession) throw WIRE_MODERATION_SESSION_ERROR;
      const moderationDpopProofPool =
        await createWireModerationDpopProofPool(oauthSession);
      return wirePageToEntriesPage(
        await getWire({
          cursor,
          language,
          signal,
          oauthSession,
          moderationDpopProofPool,
        }),
      );
    },
    [
      language,
      oauthSession,
      requireModerationReady,
      viewerModerationCapable,
    ],
  );
  const moreQuery = useInfiniteQuery({
    queryKey: [
      "wireEditionMore",
      languageKey,
      regionKey,
      modeKey,
      firstEdition?.generationId ?? "pending",
    ],
    queryFn: ({ pageParam, signal }) => fetchMorePage(pageParam, signal),
    initialPageParam: initialMoreCursor ?? "",
    getNextPageParam: (lastPage) => lastPage.cursor,
    enabled: false,
    staleTime: 60_000,
    gcTime: 7 * 24 * 60 * 60_000,
    retry: 1,
  });

  const refreshFirstPageMutation = useMutation({
    mutationKey: ["refreshWireEdition", languageKey, regionKey, modeKey],
    mutationFn: async () => fetchEditionPage(),
    onSuccess: (fresh) => {
      queryClient.removeQueries({
        queryKey: ["wireEditionMore", languageKey, regionKey, modeKey],
      });
      replaceWireEditionQueryGeneration(
        queryClient,
        languageKey,
        regionKey,
        modeKey,
        fresh,
      );
    },
  });
  const refreshFirstPage = refreshFirstPageMutation.mutateAsync;
  const retryTheWire = useCallback(async (): Promise<unknown> => {
    if (moderationCapability.isError) return moderationCapability.refetch();
    if (moderationSessionUnavailable) throw WIRE_MODERATION_SESSION_ERROR;
    if (query.data?.pages.length) return refreshFirstPage();
    return query.refetch();
  }, [
    moderationCapability,
    moderationSessionUnavailable,
    query,
    refreshFirstPage,
  ]);

  useEffect(() => {
    if (
      !args.refreshCachedOnMount ||
      !query.data?.pages.length ||
      query.isFetchedAfterMount ||
      !query.isSuccess
    ) {
      return;
    }
    const firstPage = query.data.pages[0];
    const refreshKey = `${languageKey}:${modeKey}:${firstPage?.generationId ?? ""}`;
    if (refreshKeyRef.current === refreshKey) return;
    refreshKeyRef.current = refreshKey;
    void refreshFirstPage().catch(() => {
      // A persisted edition remains useful during a partial outage.
    });
  }, [
    args.refreshCachedOnMount,
    languageKey,
    modeKey,
    query.data?.pages,
    query.isFetchedAfterMount,
    query.isSuccess,
    refreshFirstPage,
  ]);

  return {
    ...query,
    error:
      moderationCapability.error ??
      (moderationSessionUnavailable
        ? WIRE_MODERATION_SESSION_ERROR
        : query.error),
    isError:
      moderationSessionUnavailable ||
      moderationCapability.isError ||
      query.isError,
    isLoading: moderationCheckPending || query.isLoading,
    catalog,
    language,
    refreshFirstPage,
    retryTheWire,
    isRefreshingFirstPage: refreshFirstPageMutation.isPending,
    viewerModerationNeedsReauth,
    viewerModerationRetryUnavailable: moderationSessionUnavailable,
    viewerModerationError:
      moderationSessionUnavailable ||
      (Boolean(session && oauthSession) && moderationCapability.isError) ||
      (viewerModerationCapable &&
        (query.isError ||
          query.isRefetchError ||
          refreshFirstPageMutation.isError)),
    moreStories:
      moreQuery.data?.pages.flatMap((page) => page.entries) ?? [],
    fetchNextPage: moreQuery.fetchNextPage,
    hasNextPage:
      Boolean(initialMoreCursor) &&
      (moreQuery.data == null || moreQuery.hasNextPage),
    isFetchingNextPage: moreQuery.isFetchingNextPage,
    isFetchNextPageError: moreQuery.isFetchNextPageError,
  };
}
