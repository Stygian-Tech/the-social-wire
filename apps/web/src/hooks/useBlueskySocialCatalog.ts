"use client";

import { useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskySocialCatalog, type BlueskySocialCatalog } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

const safetyByClient = new WeakMap<QueryClient, Map<string, { oauth: object; ready?: BlueskySocialCatalog }>>();

export function useBlueskySocialCatalog({ enabled = true }: { enabled?: boolean } = {}) {
  const { session, getOAuthSession } = useAuth();
  const client = useQueryClient();
  const key = ["blueskySocial", session?.did ?? "", "catalog", "cache-v1"];
  const query = useQuery({
    queryKey: key,
    enabled: enabled && !!session,
    queryFn: ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did) throw new Error("Your account changed. Please reload this feed.");
      let requests = safetyByClient.get(client);
      if (!requests) { requests = new Map(); safetyByClient.set(client, requests); }
      const request: { oauth: object; ready?: BlueskySocialCatalog } = { oauth };
      requests.set(JSON.stringify(key), request);
      return getBlueskySocialCatalog(oauth, signal, { previousCatalog: client.getQueryData<BlueskySocialCatalog>(key), onReady: catalog => {
        if (!signal.aborted && getOAuthSession() === oauth) {
          request.ready = catalog;
          client.setQueryData(key, catalog);
        }
      } }).finally(() => {
        if (requests.get(JSON.stringify(key)) === request) requests.delete(JSON.stringify(key));
      });
    },
    staleTime: 60_000,
    gcTime: 7 * 24 * 60 * 60 * 1000,
    refetchOnMount: "always",
    retry: false,
  });
  // onReady may be published by another observer of this shared catalog query.
  // Wait for verified safety, not the optional saved-feed metadata tail.
  const refetchSafety = () => new Promise<BlueskySocialCatalog>((resolve, reject) => {
    const oauth = getOAuthSession();
    const pending = safetyByClient.get(client)?.get(JSON.stringify(key));
    const unsubscribe = client.getQueryCache().subscribe(event => {
      if (event.type !== "updated" || event.action.type !== "success" || !event.action.manual) return;
      if (JSON.stringify(event.query.queryKey) !== JSON.stringify(key) || getOAuthSession() !== oauth) return;
      const catalog = event.query.state.data as BlueskySocialCatalog;
      if (catalog?.moderation.userDid !== oauth?.did) return;
      unsubscribe();
      resolve(catalog);
    });
    // A completed safety phase belongs to the preceding gesture. Retire its
    // optional metadata tail so this gesture gets fresh preferences; only an
    // unfinished safety phase can be shared by concurrent refresh callers.
    void query.refetch({ cancelRefetch: !!pending && (pending.ready !== undefined || pending.oauth !== oauth) }).then(result => {
      unsubscribe();
      if (result.isError) reject(result.error);
      else if (result.data && getOAuthSession() === oauth) resolve(result.data);
      else reject(new Error("Your account changed. Please reload this feed."));
    }, error => { unsubscribe(); reject(error); });
  });
  return { ...query, refetchSafety };
}
