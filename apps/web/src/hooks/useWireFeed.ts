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

import { entriesNextPageParam } from "@/hooks/useEntries";
import {
  createWireModerationDpopProofPool,
  getWire,
  getWireFeedCatalog,
  selectWireLanguage,
  wirePageToEntriesPage,
  type WireEntriesPage,
} from "@/lib/wireFeedClient";
import { recordClientPerformance } from "@/lib/clientPerformanceTelemetry";
import { useAuth } from "@/hooks/useAuth";
import { WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";

export const WIRE_CATALOG_QUERY_KEY = ["wireFeedCatalog"] as const;
export const WIRE_ENTRIES_QUERY_KEY = (language: string, modeKey: string) =>
  ["wireEntries", language, modeKey] as const;
export const WIRE_REFRESH_STATUS_QUERY_KEY = (
  language: string,
  modeKey: string,
) => ["wireRefreshStatus", language, modeKey] as const;

export type WireRefreshStatus = {
  isPending: boolean;
  error: unknown | null;
};

export const IDLE_WIRE_REFRESH_STATUS: WireRefreshStatus = {
  isPending: false,
  error: null,
};

const WIRE_MODERATION_SESSION_ERROR = new Error(
  "Your moderation settings could not be applied to The Wire; retry.",
);

export function hasWireModerationScopes(scope: unknown): boolean {
  const granted = new Set(
    String(scope ?? "")
      .split(/\s+/)
      .filter(Boolean),
  );
  return WIRE_MODERATION_RPC_SCOPES.every((required) => granted.has(required));
}

export function replaceWireQueryGeneration(
  queryClient: QueryClient,
  languageKey: string,
  modeKey: string,
  fresh: WireEntriesPage,
): void {
  queryClient.setQueryData<
    InfiniteData<WireEntriesPage, string | undefined>
  >(WIRE_ENTRIES_QUERY_KEY(languageKey, modeKey), {
    pages: [fresh],
    pageParams: [undefined],
  });
}

export function setWireRefreshStatus(
  queryClient: QueryClient,
  languageKey: string,
  modeKey: string,
  status: WireRefreshStatus,
): void {
  queryClient.setQueryData(
    WIRE_REFRESH_STATUS_QUERY_KEY(languageKey, modeKey),
    status,
  );
}

export function useWireFeedCatalog() {
  return useQuery({
    queryKey: WIRE_CATALOG_QUERY_KEY,
    queryFn: ({ signal }) => getWireFeedCatalog(signal),
    staleTime: 60_000,
    gcTime: 60 * 60_000,
    retry: 1,
    refetchOnWindowFocus: false,
  });
}

export function useWireFeedEntries(args: {
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
  const language = useMemo(
    () => selectWireLanguage(catalog.data?.supportedLanguages ?? []),
    [catalog.data?.supportedLanguages],
  );
  const languageKey = language ?? "default";
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
      return hasWireModerationScopes(info.scope);
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
    Boolean(session) && !authLoading && !oauthSession;
  const viewerModerationCapable = moderationCapability.data === true;
  const viewerModerationNeedsReauth =
    Boolean(session && oauthSession) && moderationCapability.data === false;
  const modeKey =
    moderationCheckPending ||
    moderationSessionUnavailable ||
    moderationCapability.isError
      ? `checking:${session?.did ?? "public"}`
      : viewerModerationCapable
        ? `viewer:${session?.did ?? "unknown"}`
        : "baseline";
  const queryKey = WIRE_ENTRIES_QUERY_KEY(languageKey, modeKey);
  const refreshStatus = useQuery({
    queryKey: WIRE_REFRESH_STATUS_QUERY_KEY(languageKey, modeKey),
    queryFn: async () => IDLE_WIRE_REFRESH_STATUS,
    initialData: IDLE_WIRE_REFRESH_STATUS,
    enabled: false,
    gcTime: 60 * 60_000,
  });
  const refreshKeyRef = useRef<string | null>(null);
  const telemetryKeyRef = useRef<string | null>(null);
  const errorTelemetryKeyRef = useRef<string | null>(null);
  const paintStartedRef = useRef(0);

  useEffect(() => {
    paintStartedRef.current = performance.now();
  }, [languageKey, modeKey]);

  const fetchWirePage = useCallback(
    async (cursor?: string, signal?: AbortSignal) => {
      if (
        moderationCheckPending ||
        moderationSessionUnavailable ||
        moderationCapability.isError
      ) {
        throw moderationCapability.error instanceof Error
          ? moderationCapability.error
          : WIRE_MODERATION_SESSION_ERROR;
      }
      if (!viewerModerationCapable) {
        return getWire({ cursor, language, signal });
      }
      if (!oauthSession) {
        throw WIRE_MODERATION_SESSION_ERROR;
      }
      const moderationDpopProofPool =
        await createWireModerationDpopProofPool(oauthSession);
      return getWire({
        cursor,
        language,
        signal,
        oauthSession,
        moderationDpopProofPool,
      });
    },
    [
      language,
      moderationCapability.error,
      moderationCapability.isError,
      moderationCheckPending,
      moderationSessionUnavailable,
      oauthSession,
      viewerModerationCapable,
    ],
  );

  const query = useInfiniteQuery({
    queryKey,
    queryFn: async ({ pageParam, signal }) =>
      wirePageToEntriesPage(await fetchWirePage(pageParam, signal)),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: entriesNextPageParam,
    enabled:
      args.enabled &&
      !moderationCheckPending &&
      !moderationSessionUnavailable &&
      !moderationCapability.isError &&
      catalog.data?.enabled === true &&
      catalog.data.available === true,
    staleTime: 60_000,
    gcTime: 7 * 24 * 60 * 60_000,
    refetchOnMount: false,
    refetchOnWindowFocus: false,
    retry: 1,
  });

  const refreshFirstPageMutation = useMutation({
    mutationKey: ["refreshWireFirstPage", languageKey, modeKey],
    mutationFn: async () => wirePageToEntriesPage(await fetchWirePage()),
    onMutate: () => {
      setWireRefreshStatus(queryClient, languageKey, modeKey, {
        isPending: true,
        error: null,
      });
    },
    onSuccess: (fresh) => {
      replaceWireQueryGeneration(queryClient, languageKey, modeKey, fresh);
      setWireRefreshStatus(
        queryClient,
        languageKey,
        modeKey,
        IDLE_WIRE_REFRESH_STATUS,
      );
    },
    onError: (error) => {
      setWireRefreshStatus(queryClient, languageKey, modeKey, {
        isPending: false,
        error,
      });
    },
  });
  const refreshFirstPage = refreshFirstPageMutation.mutateAsync;
  const retryTheWire = useCallback(async (): Promise<unknown> => {
    if (moderationCapability.isError) {
      return moderationCapability.refetch();
    }
    if (moderationSessionUnavailable) {
      throw WIRE_MODERATION_SESSION_ERROR;
    }
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
    const refreshKey = `${languageKey}:${modeKey}:${query.data.pages[0]?.generationId ?? ""}`;
    if (refreshKeyRef.current === refreshKey) return;
    refreshKeyRef.current = refreshKey;
    void refreshFirstPage().catch(() => {
      // Persisted ranked rows remain useful during a partial outage.
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

  useEffect(() => {
    if (!args.refreshCachedOnMount || !query.isSuccess) return;
    const generationId = query.data?.pages[0]?.generationId;
    if (!generationId || telemetryKeyRef.current === generationId) return;
    telemetryKeyRef.current = generationId;
    const oauth = getOAuthSession();
    if (!oauth) return;
    const cacheHit = !query.isFetchedAfterMount;
    const durationMs = performance.now() - paintStartedRef.current;
    void recordClientPerformance(oauth, {
      event: cacheHit ? "cached_feed_paint" : "uncached_feed_paint",
      durationMs,
      feedType: "wire",
      cacheState: cacheHit ? "hit" : "miss",
      outcome: "success",
    }).catch(() => undefined);
    void recordClientPerformance(oauth, {
      event: "feed_switch",
      durationMs,
      feedType: "wire",
      cacheState: cacheHit ? "hit" : "miss",
      outcome: "success",
    }).catch(() => undefined);
  }, [
    args.refreshCachedOnMount,
    getOAuthSession,
    query.data?.pages,
    query.isFetchedAfterMount,
    query.isSuccess,
  ]);

  useEffect(() => {
    if (!args.refreshCachedOnMount || !query.isError) return;
    const key = `${languageKey}:${String(query.error)}`;
    if (errorTelemetryKeyRef.current === key) return;
    errorTelemetryKeyRef.current = key;
    const oauth = getOAuthSession();
    if (!oauth) return;
    void recordClientPerformance(oauth, {
      event: "feed_error",
      durationMs: performance.now() - paintStartedRef.current,
      feedType: "wire",
      cacheState: query.data?.pages.length ? "hit" : "miss",
      outcome: "error",
    }).catch(() => undefined);
  }, [
    args.refreshCachedOnMount,
    getOAuthSession,
    languageKey,
    query.data?.pages.length,
    query.error,
    query.isError,
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
    isRefreshingFirstPage: refreshStatus.data.isPending,
    viewerModerationApplied:
      viewerModerationCapable && Boolean(query.data?.pages.length),
    viewerModerationNeedsReauth,
    viewerModerationRetryUnavailable: moderationSessionUnavailable,
    viewerModerationError:
      moderationSessionUnavailable ||
      (Boolean(session && oauthSession) && moderationCapability.isError) ||
      (viewerModerationCapable &&
        (query.isError ||
          query.isRefetchError ||
          refreshStatus.data.error !== null)),
  };
}
