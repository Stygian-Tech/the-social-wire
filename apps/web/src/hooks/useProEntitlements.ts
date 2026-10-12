"use client";

import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { getProEntitlements, isProGatingEnabled } from "@/lib/proEntitlements";

export function useProEntitlements() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const did = session?.did;
  const gatingEnabled = isProGatingEnabled();
  const query = useQuery({
    queryKey: ["proEntitlements", did, oauthSessionReloadSeq],
    enabled: !!did && gatingEnabled,
    staleTime: 0,
    refetchInterval: 60_000,
    retry: false,
    queryFn: ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth || oauth.did !== did) throw new Error("Your Account Changed. Retry Pro Access.");
      return getProEntitlements(oauth, signal);
    },
  });
  // isPro represents feature access; disabling enforcement does not change the viewer's plan.
  return { ...query, isPro: !!did && (!gatingEnabled || (!query.isError && query.data?.viewerDid === did && query.data.plan === "pro")) };
}
