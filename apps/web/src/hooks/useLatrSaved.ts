"use client";

import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { MergedLatrSave } from "@/lib/pdsClient";
import { normalizeLatrHttpsUrl } from "@/lib/latrSavedUrls";
import { createReadLaterProvider } from "@/lib/readLaterProvider";
import { useAuth } from "./useAuth";
import { usePDSClient } from "./usePDSClient";

export const LATR_SAVED_QUERY_KEY = ["latrSavedHttps"] as const;

function useReadLaterProvider() {
  const client = usePDSClient();
  const { session, getOAuthSession } = useAuth();

  return useMemo(() => {
    if (!client || !session) return null;
    const oauthSession = getOAuthSession();
    if (!oauthSession) return null;
    return createReadLaterProvider(oauthSession, client, session.did);
  }, [client, session, getOAuthSession]);
}

export function useLatrMergedHttpsSaves() {
  const client = usePDSClient();
  return useQuery({
    queryKey: LATR_SAVED_QUERY_KEY,
    queryFn: async ({ signal }): Promise<MergedLatrSave[]> => {
      if (!client) return [];
      return client.listMergedLatrSaves(signal);
    },
    enabled: !!client,
    staleTime: 15_000,
  });
}

export function useSaveHttpsReadLaterMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (params: {
      url: string;
      title?: string;
      excerpt?: string;
    }) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.saveHttpsUrl(params.url, {
        title: params.title,
        excerpt: params.excerpt,
      });
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: LATR_SAVED_QUERY_KEY }),
  });
}

export function useDeleteHttpsReadLaterMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (normalizedUrl: string) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.deleteHttpsUrl(normalizedUrl);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: LATR_SAVED_QUERY_KEY }),
  });
}

export function useArchiveHttpsReadLaterMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (normalizedUrl: string) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.archiveHttpsUrl(normalizedUrl);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: LATR_SAVED_QUERY_KEY }),
  });
}

/**
 * Client-only: whether merged read-later rows already include this HTTPS URL string.
 */
export function useHttpsUrlIsLatrSaved(displayUrlHttps: string | null | undefined): boolean {
  const { data: merged } = useLatrMergedHttpsSaves();
  const n = displayUrlHttps?.trim()
    ? normalizeLatrHttpsUrl(displayUrlHttps)
    : null;
  return useMemo(() => {
    if (!n || !merged?.length) return false;
    return merged.some((row) => row.kind === "external" && row.normalizedUrl === n);
  }, [n, merged]);
}
