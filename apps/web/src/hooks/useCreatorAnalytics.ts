"use client";

import { useLayoutEffect, useRef } from "react";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { getCreatorAnalytics, uniqueAnalyticsItems } from "@/lib/analytics/creatorAnalyticsClient";

export function useCreatorAnalytics(days: number) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const client = useQueryClient();
  const viewer = useRef(session?.did);
  const mounted = useRef(true);
  useLayoutEffect(() => { viewer.current = session?.did; mounted.current = true; return () => { mounted.current = false; }; }, [session?.did]);
  function requireSession(did = session?.did) {
    const oauth = getOAuthSession();
    if (!did || !oauth) throw new Error("Log in again to allow Analytics to access your account.");
    if (!mounted.current || oauth.did !== did || viewer.current !== did) throw new Error("Your account changed. Please reload Analytics.");
    return oauth;
  }
  const key = ["creatorAnalytics", session?.did ?? "", oauthSessionReloadSeq, days] as const;
  const query = useInfiniteQuery({
    queryKey: key, enabled: !!session, initialPageParam: undefined as string | undefined,
    queryFn: async ({ pageParam, signal }) => {
      const did = session?.did;
      const result = await getCreatorAnalytics(requireSession(did), { days, cursor: pageParam, signal });
      requireSession(did);
      return result;
    },
    getNextPageParam: (page, _pages, _param, params) => page.cursor && !params.includes(page.cursor) ? page.cursor : undefined,
    retry: false, staleTime: 60_000,
  });
  const refresh = useMutation({
    mutationFn: async ({ did, period }: { did: string; period: number }) => {
      await getCreatorAnalytics(requireSession(did), { days: period, refresh: true });
      requireSession(did);
    },
    onSuccess: (_result, args) => { if (viewer.current === args.did) void client.invalidateQueries({ queryKey: ["creatorAnalytics", args.did] }); },
  });
  return { query, summary: query.data?.pages[0], items: uniqueAnalyticsItems(query.data?.pages ?? []), refresh, collect: () => refresh.mutateAsync({ did: session!.did, period: days }) };
}
