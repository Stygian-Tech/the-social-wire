"use client";

import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { usePDSClient } from "@/hooks/usePDSClient";
import type { RepoRecord } from "@/lib/pdsClient";
import {
  normalizeWireFeedbackUrl,
  type WireArticleFeedbackRecord,
  type WireArticleFeedbackValue,
} from "@/lib/wireArticleFeedback";

export const WIRE_ARTICLE_FEEDBACK_QUERY_KEY = ["wireArticleFeedback"] as const;

export function useWireArticleFeedback(
  canonicalUrl: string | null | undefined,
  subject?: string | null,
) {
  const client = usePDSClient();
  const queryClient = useQueryClient();
  const normalizedUrl = canonicalUrl
    ? normalizeWireFeedbackUrl(canonicalUrl)
    : null;
  const query = useQuery({
    queryKey: WIRE_ARTICLE_FEEDBACK_QUERY_KEY,
    queryFn: () => client!.listWireArticleFeedback(),
    enabled: !!client && !!normalizedUrl,
    staleTime: 30_000,
    refetchOnWindowFocus: false,
  });
  const existing = useMemo(
    () =>
      normalizedUrl
        ? (query.data ?? []).find(
            (record) =>
              normalizeWireFeedbackUrl(record.value.canonicalUrl) === normalizedUrl,
          )
        : undefined,
    [normalizedUrl, query.data],
  );

  const mutation = useMutation({
    mutationFn: async (value: WireArticleFeedbackValue) => {
      if (!client || !normalizedUrl) {
        throw new Error("Sign in again to rate this article.");
      }
      if (existing?.value.value === value) {
        await client.deleteWireArticleFeedback(normalizedUrl);
      } else {
        await client.putWireArticleFeedback({
          canonicalUrl: normalizedUrl,
          ...(subject?.startsWith("at://") ? { subject } : {}),
          value,
          createdAt: existing?.value.createdAt,
        });
      }
    },
    onMutate: async (value) => {
      if (!normalizedUrl) return undefined;
      await queryClient.cancelQueries({ queryKey: WIRE_ARTICLE_FEEDBACK_QUERY_KEY });
      const previous = queryClient.getQueryData<
        RepoRecord<WireArticleFeedbackRecord>[]
      >(WIRE_ARTICLE_FEEDBACK_QUERY_KEY);
      const current = previous ?? [];
      const withoutCurrent = current.filter(
        (record) =>
          normalizeWireFeedbackUrl(record.value.canonicalUrl) !== normalizedUrl,
      );
      queryClient.setQueryData<RepoRecord<WireArticleFeedbackRecord>[]>(
        WIRE_ARTICLE_FEEDBACK_QUERY_KEY,
        existing?.value.value === value
          ? withoutCurrent
          : [
              ...withoutCurrent,
              {
                uri: "at://optimistic/app.thesocialwire.wireFeedback/pending",
                cid: "pending",
                value: {
                  $type: "app.thesocialwire.wireFeedback",
                  canonicalUrl: normalizedUrl,
                  ...(subject?.startsWith("at://") ? { subject } : {}),
                  value,
                  createdAt: existing?.value.createdAt ?? new Date().toISOString(),
                  updatedAt: new Date().toISOString(),
                },
              },
            ],
      );
      return previous;
    },
    onError: (_error, _value, previous) => {
      queryClient.setQueryData(WIRE_ARTICLE_FEEDBACK_QUERY_KEY, previous);
    },
    onSettled: () =>
      queryClient.invalidateQueries({ queryKey: WIRE_ARTICLE_FEEDBACK_QUERY_KEY }),
  });

  return {
    applicable: !!normalizedUrl,
    signedIn: !!client,
    value: existing?.value.value,
    isLoading: query.isLoading,
    mutation,
  };
}
