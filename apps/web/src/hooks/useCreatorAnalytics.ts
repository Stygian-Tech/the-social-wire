"use client";

import { useLayoutEffect, useRef } from "react";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { getStoredOAuthDid } from "@/lib/auth";
import { useAuth } from "@/hooks/useAuth";
import { getCreatorAnalytics, uniqueAnalyticsItems } from "@/lib/analytics/creatorAnalyticsClient";
import { listBrandAccounts, restoreBrandAccount } from "@/lib/brandAccounts/brandAccountSessions";

export function useCreatorAnalytics(days: number, accountDid?: string) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const owner = session?.did;
  const actor = accountDid ?? owner;
  const client = useQueryClient();
  const identity = useRef({ owner, actor });
  const mounted = useRef(true);
  useLayoutEffect(() => { identity.current = { owner, actor }; mounted.current = true; return () => { mounted.current = false; }; }, [owner, actor]);
  function assertIdentity(expectedOwner = owner, expectedActor = actor) {
    if (!mounted.current || !expectedOwner || !expectedActor || identity.current.owner !== expectedOwner || identity.current.actor !== expectedActor || getOAuthSession()?.did !== expectedOwner || getStoredOAuthDid() !== expectedOwner) throw new Error("Your account changed. Please reload Analytics.");
    if (expectedActor !== expectedOwner && !listBrandAccounts(expectedOwner).includes(expectedActor)) throw new Error("This brand account is no longer linked.");
  }
  async function requireSession(expectedOwner = owner, expectedActor = actor) {
    if (!expectedOwner || !expectedActor || !getOAuthSession()) throw new Error("Log in again to allow Analytics to access your account.");
    assertIdentity(expectedOwner, expectedActor);
    const oauth = expectedActor === expectedOwner ? getOAuthSession()! : await restoreBrandAccount(expectedOwner, expectedActor);
    assertIdentity(expectedOwner, expectedActor);
    if (oauth.did !== expectedActor) throw new Error("Your account changed. Please reload Analytics.");
    return oauth;
  }
  const key = accountDid && accountDid !== owner ? ["creatorAnalytics", owner ?? "", oauthSessionReloadSeq, days, actor] as const : ["creatorAnalytics", owner ?? "", oauthSessionReloadSeq, days] as const;
  const query = useInfiniteQuery({
    queryKey: key, enabled: !!owner && !!actor, initialPageParam: undefined as string | undefined,
    queryFn: async ({ pageParam, signal }) => {
      const result = await getCreatorAnalytics(await requireSession(owner, actor), { days, cursor: pageParam, signal });
      assertIdentity(owner, actor);
      return result;
    },
    getNextPageParam: (page, _pages, _param, params) => page.cursor && !params.includes(page.cursor) ? page.cursor : undefined,
    retry: false, staleTime: 60_000,
  });
  const refresh = useMutation({
    mutationFn: async ({ did, actingDid, period }: { did: string; actingDid: string; period: number }) => {
      await getCreatorAnalytics(await requireSession(did, actingDid), { days: period, refresh: true });
      assertIdentity(did, actingDid);
    },
    onSuccess: (_result, args) => { if (identity.current.owner === args.did && identity.current.actor === args.actingDid) void client.invalidateQueries({ queryKey: ["creatorAnalytics", args.did] }); },
  });
  return { query, summary: query.data?.pages[0], items: uniqueAnalyticsItems(query.data?.pages ?? []), refresh, collect: () => refresh.mutateAsync({ did: owner!, actingDid: actor!, period: days }) };
}
