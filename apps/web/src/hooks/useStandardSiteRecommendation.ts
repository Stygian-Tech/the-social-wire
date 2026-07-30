"use client";

import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { usePDSClient } from "@/hooks/usePDSClient";
import {
  standardSiteRecommendDocumentUri,
  type StandardSiteRecommendRecord,
} from "@/lib/standardSiteRecommendation";
import type { RepoRecord } from "@/lib/pdsClient";

export const STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY = [
  "standardSiteRecommendations",
] as const;

export function useStandardSiteRecommendation(
  entryId: string | null | undefined
) {
  const client = usePDSClient();
  const queryClient = useQueryClient();
  const documentUri = standardSiteRecommendDocumentUri(entryId);

  const recommendationsQuery = useQuery({
    queryKey: STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY,
    queryFn: () => client!.listStandardSiteRecommendations(),
    enabled: !!client && !!documentUri,
    staleTime: 30_000,
    refetchOnWindowFocus: false,
  });

  const matchingRecommendations = useMemo(
    () =>
      documentUri
        ? (recommendationsQuery.data ?? []).filter(
            (record) => record.value.document === documentUri
          )
        : [],
    [documentUri, recommendationsQuery.data]
  );

  const toggleMutation = useMutation({
    mutationFn: async () => {
      if (!client || !documentUri) {
        throw new Error("This article cannot be recommended.");
      }
      if (matchingRecommendations.length > 0) {
        await Promise.all(
          matchingRecommendations.map((record) =>
            client.deleteStandardSiteRecommendation(record.uri)
          )
        );
        return;
      }
      await client.createStandardSiteRecommendation(documentUri);
    },
    onMutate: async () => {
      if (!documentUri) return undefined;
      await queryClient.cancelQueries({
        queryKey: STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY,
      });
      const previous = queryClient.getQueryData<
        RepoRecord<StandardSiteRecommendRecord>[]
      >(STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY);
      const current = previous ?? [];
      queryClient.setQueryData<RepoRecord<StandardSiteRecommendRecord>[]>(
        STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY,
        matchingRecommendations.length > 0
          ? current.filter((record) => record.value.document !== documentUri)
          : [
              ...current,
              {
                uri: `at://optimistic/${STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY[0]}/pending`,
                cid: "pending",
                value: {
                  $type: "site.standard.graph.recommend",
                  document: documentUri,
                  createdAt: new Date().toISOString(),
                },
              },
            ]
      );
      return previous;
    },
    onError: (_error, _variables, previous) => {
      queryClient.setQueryData(
        STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY,
        previous
      );
    },
    onSettled: () =>
      queryClient.invalidateQueries({
        queryKey: STANDARD_SITE_RECOMMENDATIONS_QUERY_KEY,
      }),
  });

  return {
    applicable: !!documentUri,
    recommended: matchingRecommendations.length > 0,
    isLoading: recommendationsQuery.isLoading,
    toggleMutation,
  };
}
