"use client";
import { useEffect, useRef } from "react";
import { useIsMutating, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { MoreHorizontal } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { usePDSClient } from "@/hooks/usePDSClient";
import { useSubscribeToPublication, useUnsubscribePublication } from "@/hooks/usePublications";
import { STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY } from "@/hooks/useStandardSiteRecommendation";
import { parseAtUri, type DiscoveredPublication } from "@/lib/atprotoClient";
import { performStandardSiteArticleAction } from "@/lib/standardSiteEmbedActions";
import type { StandardSiteEmbed } from "@/lib/standardSiteEmbedClient";
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem } from "@/components/ui/dropdown-menu";

export function StandardSiteArticleActions({ metadata }: { metadata: StandardSiteEmbed }) {
  const { session, oauthSessionReloadSeq, getOAuthSession } = useAuth();
  const oauth = getOAuthSession();
  const client = usePDSClient();
  const queryClient = useQueryClient();
  const locked = useRef(false);
  const subscribe = useSubscribeToPublication();
  const unsubscribe = useUnsubscribePublication();
  // Viewer records must never be shared across account or OAuth-session changes.
  const queryKey = ["socialArticleViewer", session?.did, oauthSessionReloadSeq];
  const viewer = useQuery({
    queryKey,
    queryFn: async () => {
      const [subscriptions, recommendations] = await Promise.all([client!.listPublicationSubscriptions(), client!.listStandardSiteRecommendations()]);
      return { subscriptions, recommendations };
    },
    enabled: !!client,
    staleTime: 30_000,
  });
  useEffect(() => queryClient.getQueryCache().subscribe(event => {
    const key = event.query.queryKey[0];
    if (event.type === "updated" && (event.action.type === "invalidate" || event.action.type === "success") &&
        (key === "publicationSubscriptions" || key === STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY[0])) {
      void queryClient.invalidateQueries({ queryKey: ["socialArticleViewer", session?.did, oauthSessionReloadSeq] });
    }
  }), [queryClient, session?.did, oauthSessionReloadSeq]);
  const subscriptions = viewer.data?.subscriptions.filter(row => row.value.publication === metadata.publicationUri) ?? [];
  const recommendations = viewer.data?.recommendations.filter(row => row.value.document === metadata.documentUri) ?? [];
  const publication: DiscoveredPublication = {
    publicationId: metadata.publicationUri,
    authorDid: parseAtUri(metadata.publicationUri)!.did,
    authorHandle: "",
    title: metadata.publicationName,
    discoveredAt: "",
  };
  const mutationKey = ["socialArticleAction", session?.did, oauthSessionReloadSeq];
  const pending = useIsMutating({ mutationKey });
  const action = useMutation({
    mutationKey,
    mutationFn: async (kind: "subscription" | "recommendation") => {
      if (locked.current || !client || !viewer.data || viewer.isError) return;
      const checkSession = () => {
        if (!oauth || getOAuthSession() !== oauth) throw new Error("Account changed. Retry from the current account.");
      };
      checkSession();
      locked.current = true;
      try {
        await performStandardSiteArticleAction({
          kind, metadata, assertSession: checkSession,
          remove: kind === "subscription" ? subscriptions.length > 0 : recommendations.length > 0,
          readViewer: async () => {
            const current = await viewer.refetch();
            if (current.isError || !current.data) throw new Error("Unable to load current article actions.");
            return current.data;
          },
          subscribe: () => subscribe.mutateAsync({ publication }),
          unsubscribe: uri => unsubscribe.mutateAsync({ publication: { ...publication, subscriptionPublicationId: uri } }),
          recommend: () => client.createStandardSiteRecommendation(metadata.documentUri),
          unrecommend: uri => client.deleteStandardSiteRecommendation(uri),
        });
      } finally { locked.current = false; }
    },
    onSettled: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey }),
        queryClient.invalidateQueries({ queryKey: STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY }),
      ]);
    },
  });
  const disabled = !client || !viewer.data || viewer.isError || viewer.isFetching || action.isPending || pending > 0;
  return <>
    <DropdownMenu>
      <DropdownMenuTrigger aria-label="Article Actions" className="ml-auto flex min-h-11 min-w-11 items-center justify-center rounded-md hover:bg-muted"><MoreHorizontal className="size-5" /></DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem disabled={disabled} onClick={() => action.mutate("subscription")}>{subscriptions.length ? "Unsubscribe" : "Subscribe"}</DropdownMenuItem>
        <DropdownMenuItem disabled={disabled || parseAtUri(metadata.documentUri)?.collection !== "site.standard.document"} onClick={() => action.mutate("recommendation")}>{recommendations.length ? "Unrecommend" : "Recommend"}</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
    {action.isError ? <p role="alert" className="w-full px-3 pb-2 text-sm text-destructive">{action.error instanceof Error ? action.error.message : "Unable to update article."}</p> : null}
    {viewer.isError ? <button type="button" onClick={() => void viewer.refetch()} className="px-3 py-2 text-sm underline">Retry Article Actions</button> : null}
  </>;
}
