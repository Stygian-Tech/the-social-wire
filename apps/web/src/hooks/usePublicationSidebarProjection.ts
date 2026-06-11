"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";

import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";

/**
 * Subscribes to the sidebar projection React Query cache (populated by bootstrap stream).
 */
export function usePublicationSidebarProjection(
  viewerDid: string | undefined
): PublicationSidebarProjection | undefined {
  const queryClient = useQueryClient();
  const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid ?? "");

  const { data } = useQuery({
    queryKey,
    enabled: !!viewerDid,
    staleTime: Infinity,
    gcTime: Infinity,
    refetchOnMount: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    queryFn: () =>
      queryClient.getQueryData<PublicationSidebarProjection>(queryKey),
  });

  return data;
}
