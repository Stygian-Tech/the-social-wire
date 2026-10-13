"use client";

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { composeLinkUrl, type ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { fetchLatrOgPreview } from "@/lib/latrSaveMetadataBackfill";

export function useComposeLinkPreview(text: string, session: OAuthSession | null | undefined, enabled = true, initialRemovedUrl?: string) {
  const url = enabled ? composeLinkUrl(text) : undefined;
  const [removed, setRemoved] = useState<string | undefined>(initialRemovedUrl);
  const [settledUrl, setSettledUrl] = useState<string>();
  useEffect(() => {
    const timer = setTimeout(() => setSettledUrl(url), 350);
    return () => clearTimeout(timer);
  }, [url]);
  const active = !!url && url !== removed && enabled;
  const query = useQuery({
    queryKey: ["blueskySocial", session?.did, "composeLinkPreview", url],
    enabled: active && url === settledUrl && !!session,
    queryFn: async ({ signal }): Promise<ComposeLinkPreview | null> => {
      const metadata = await fetchLatrOgPreview(session!, url!, AbortSignal.any([signal, AbortSignal.timeout(10_000)]));
      return metadata ? { uri: url!, title: metadata.title || new URL(url!).hostname, description: metadata.excerpt || "", image: metadata.image } : null;
    },
    retry: false,
    staleTime: 10 * 60_000,
  });
  return {
    removedUrl: removed,
    preview: active ? query.data ?? undefined : undefined,
    needsResolution: active && !!session && query.isPending,
    loading: active && query.isPending,
    unavailable: active && !query.isPending && !query.data,
    remove: () => setRemoved(url),
    reset: () => setRemoved(undefined),
    resolve: async () => {
      if (!active || !session) return undefined;
      // An explicit Post action can arrive before the debounce/metadata request.
      // Resolve that draft's card once; failed metadata still permits text-only posting.
      if (!query.isPending) return query.data ?? undefined;
      return (await query.refetch()).data ?? undefined;
    },
  };
}
