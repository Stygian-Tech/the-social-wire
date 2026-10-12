"use client";

import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskySocialCatalog } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskySocialCatalog({ enabled = true }: { enabled?: boolean } = {}) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  return useQuery({
    queryKey: ["blueskySocial", session?.did ?? "", "catalog", oauthSessionReloadSeq],
    enabled: enabled && !!session,
    queryFn: ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did) throw new Error("Your account changed. Please reload this feed.");
      return getBlueskySocialCatalog(oauth, signal);
    },
    staleTime: 60_000,
    retry: false,
  });
}
