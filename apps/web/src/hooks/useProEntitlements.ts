"use client";

import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { getProEntitlements } from "@/lib/proEntitlements";

export function useProEntitlements() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const did = session?.did;
  const query = useQuery({
    queryKey: ["proEntitlements", did, oauthSessionReloadSeq],
    enabled: !!did,
    staleTime: 0,
    refetchInterval: 60_000,
    retry: false,
    queryFn: ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth || oauth.did !== did) throw new Error("Your Account Changed. Retry Pro Access.");
      return getProEntitlements(oauth, signal);
    },
  });
  return { ...query, isPro: !!did && !query.isError && query.data?.viewerDid === did && query.data.plan === "pro" };
}
