"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { hasWireModerationScopes } from "@/hooks/useWireFeed";
import { useExpiredFeedCursorRecovery } from "@/hooks/useExpiredFeedCursorRecovery";
import { isExpiredFeedCursor } from "@/lib/feedResponseError";
import { selectWireLanguage, selectWireViewerRegion } from "@/lib/wireFeedClient";
import { financePreferenceFingerprint, getFinance, listFinanceSelections, reorderFinanceItems, writeFinanceSelection, type FinancePage, type FinanceSelection } from "@/lib/financeFeedClient";
import { useFinanceCatalog } from "@/hooks/useFinanceCatalog";
export function useFinanceFeed(feedID = "finance") {
    const { session, isLoading, getOAuthSession, oauthSessionReloadSeq } = useAuth();
    const oauth = getOAuthSession();
    const client = useQueryClient();
    const catalog = useFinanceCatalog();
    const language = selectWireLanguage([]) ?? "en";
    const region = selectWireViewerRegion() ?? "us-or-unspecified";
    const viewer = session?.did ?? "public";
    const selectionKey = useMemo(() => ["financeSelections", viewer, oauthSessionReloadSeq], [viewer, oauthSessionReloadSeq]);
    const selections = useQuery({ queryKey: selectionKey, queryFn: () => listFinanceSelections(oauth!, session!.did), enabled: !!oauth && !!session, staleTime: 60000 });
    const moderation = useQuery({ queryKey: ["financeModeration", session?.did ?? "public", oauthSessionReloadSeq], queryFn: async () => hasWireModerationScopes((await oauth!.getTokenInfo("auto")).scope), enabled: !!oauth && !!session, staleTime: Infinity });
    const fingerprint = financePreferenceFingerprint(selections.data ?? []);
    const mode = session ? moderation.data === true ? "viewer" : "blocked" : "baseline";
    const key = useMemo(() => ["financeEntries", feedID, viewer, language, region, mode, fingerprint, oauthSessionReloadSeq], [feedID, viewer, language, region, mode, fingerprint, oauthSessionReloadSeq]);
    const context = JSON.stringify(key);
    const currentContext = useRef(context);
    useEffect(() => { currentContext.current = context; }, [context]);
    const [refreshState, setRefreshState] = useState<{context: string; pending: boolean; error: unknown}>({context, pending: false, error: null});
    const refreshError = refreshState.context === context ? refreshState.error : null;
    const refreshing = refreshState.context === context && refreshState.pending;
    const [optimisticItems, setOptimisticItems] = useState<{
        context: string;
        items: FinancePage["items"];
    } | null>(null);
    const enabled = !isLoading && (!session || (!!oauth && moderation.data === true && selections.isSuccess));
    const feed = useInfiniteQuery({ queryKey: key, queryFn: ({ pageParam, signal }) => getFinance({ feed: feedID, cursor: pageParam, language, region: region === "us-or-unspecified" ? undefined : region, oauthSession: oauth ?? undefined, signal }), initialPageParam: undefined as string | undefined, getNextPageParam: page => page.cursor, enabled: enabled && optimisticItems?.context !== context, staleTime: 60000, gcTime: 60 * 60000, maxPages: 20, refetchOnWindowFocus: false, refetchOnMount: false, retry: (count, error) => !isExpiredFeedCursor(error) && count < 1 });
    const refresh = useCallback(async () => {
        const captured = context;
        let targetKey = key;
        let targetContext = captured;
        setRefreshState({context: captured, pending: true, error: null});
        try {
            if (oauth && viewer !== "public") {
                const latest = await listFinanceSelections(oauth, viewer);
                if (currentContext.current !== captured || getOAuthSession() !== oauth) return;
                targetKey = ["financeEntries", feedID, viewer, language, region, mode, financePreferenceFingerprint(latest), oauthSessionReloadSeq];
                targetContext = JSON.stringify(targetKey);
                client.setQueryData(selectionKey, latest);
            }
            const page = await getFinance({ feed: feedID, language, region: region === "us-or-unspecified" ? undefined : region, oauthSession: oauth ?? undefined, refreshSelections: !!oauth });
            if ((currentContext.current !== captured && currentContext.current !== targetContext) || getOAuthSession() !== oauth)
                return;
            await client.cancelQueries({ queryKey: targetKey, exact: true });
            if ((currentContext.current !== captured && currentContext.current !== targetContext) || getOAuthSession() !== oauth)
                return;
            client.setQueryData<InfiniteData<FinancePage, string | undefined>>(targetKey, { pages: [page], pageParams: [undefined] });
            setOptimisticItems(null);
        }
        catch (error) {
            if (currentContext.current === captured || currentContext.current === targetContext)
                setRefreshState({context: targetContext, pending: false, error});
        }
        finally {
            if (currentContext.current === captured || currentContext.current === targetContext)
                setRefreshState(previous => previous.context === captured || previous.context === targetContext ? {...previous, pending: false} : previous);
        }
    }, [context, feedID, language, region, mode, viewer, oauthSessionReloadSeq, selectionKey, oauth, getOAuthSession, client, key]);
    useExpiredFeedCursorRecovery(feed.error, refresh, enabled);
    const refreshedContext = useRef<string | null>(null);
    useEffect(() => {
        if (!enabled || !feed.data?.pages.length || feed.isFetchedAfterMount || optimisticItems?.context === context || refreshedContext.current === context) return;
        refreshedContext.current = context;
        void refresh();
    }, [enabled, feed.data?.pages.length, feed.isFetchedAfterMount, optimisticItems?.context, context, refresh]);
    const mutation = useMutation({ mutationFn: async ({ selection, remove }: {
            selection: FinanceSelection;
            remove: boolean;
        }) => {
            if (!oauth || !session)
                throw new Error("Sign in to customize Finance.");
            await writeFinanceSelection(oauth, session.did, selection, remove);
        }, onMutate: async ({ selection, remove }) => {
            const captured = context;
            const previous = selections.data ?? [];
            const next = remove ? previous.filter(s => s.kind !== selection.kind || s.reference !== selection.reference) : [...previous.filter(s => s.kind !== selection.kind || s.reference !== selection.reference), selection];
            const items = optimisticItems?.context === context ? optimisticItems.items : feed.data?.pages.flatMap(p => p.items) ?? [];
            await client.cancelQueries({ queryKey: selectionKey, exact: true });
            client.setQueryData(selectionKey, next);
            const nextKey = ["financeEntries", feedID, session?.did ?? "public", language, region, mode, financePreferenceFingerprint(next), oauthSessionReloadSeq];
            setOptimisticItems({ context: JSON.stringify(nextKey), items: feedID === "finance" ? reorderFinanceItems(items, next) : items });
            return { previous, captured };
        }, onError: (_error, _variables, rollback) => { if (rollback && getOAuthSession() === oauth) {
            client.setQueryData(selectionKey, rollback.previous);
            setOptimisticItems(null);
        } }, onSuccess: () => { } });
    const preview = optimisticItems?.context === context ? optimisticItems.items : null;
    return { feed, catalog, feedID, viewerDID: session?.did, selectionsLoading: !!session && (!oauth || selections.isPending), selectionsError: selections.error, selections: selections.data ?? [], items: preview ?? feed.data?.pages.flatMap(p => p.items) ?? [], suspended: preview !== null, refresh, refreshing, error: refreshError ?? mutation.error ?? selections.error ?? feed.error ?? (session && !isLoading && (!oauth || moderation.data === false) ? new Error("Sign out and sign in again to apply your moderation and Finance permissions.") : moderation.error), isLoading: feed.isLoading || isLoading || (!!session && moderation.isPending), saveSelection: mutation.mutateAsync, saving: mutation.isPending, signedIn: !!session };
}
