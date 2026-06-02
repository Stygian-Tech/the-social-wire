"use client";

import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { resolveNativeSavedSubjectPreview } from "@/lib/atprotoClient";
import {
  applyOptimisticLatrSaveArchive,
  applyOptimisticLatrSaveDelete,
  applyOptimisticLatrSaveInsert,
  applyOptimisticLatrSaveUnarchive,
  invalidateLatrSaveQueries,
  LATR_ARCHIVED_QUERY_KEY,
  LATR_SAVED_QUERY_KEY,
  restoreLatrSaveQueries,
  snapshotLatrSaveQueries,
} from "@/lib/latrSavedMutations";
import type { LatrSaveListState, MergedLatrSave } from "@/lib/pdsClient";
import {
  buildOptimisticExternalLatrSave,
  buildOptimisticNativeLatrSave,
} from "@/lib/optimisticLatrSaves";
import { normalizeLatrHttpsUrl } from "@/lib/latrSavedUrls";
import { resolveReadLaterSaveTarget } from "@/lib/readLaterSaveTarget";
import { createReadLaterProvider } from "@/lib/readLaterProvider";
import { useAuth } from "./useAuth";
import { usePDSClient } from "./usePDSClient";

export { LATR_ARCHIVED_QUERY_KEY, LATR_SAVED_QUERY_KEY };

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

function latrSavesQueryKey(state: LatrSaveListState) {
  return state === "archived" ? LATR_ARCHIVED_QUERY_KEY : LATR_SAVED_QUERY_KEY;
}

export function useLatrMergedHttpsSaves(state: LatrSaveListState = "active") {
  const client = usePDSClient();
  return useQuery({
    queryKey: latrSavesQueryKey(state),
    queryFn: async ({ signal }): Promise<MergedLatrSave[]> => {
      if (!client) return [];
      return client.listMergedLatrSaves({ state, signal });
    },
    enabled: !!client,
    staleTime: 15_000,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
}

export function useSaveHttpsReadLaterMutation() {
  const provider = useReadLaterProvider();
  const { session } = useAuth();
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
    onMutate: async (params) => {
      const did = session?.did;
      if (!did) return undefined;

      const snapshot = await snapshotLatrSaveQueries(qc);
      try {
        const row = await buildOptimisticExternalLatrSave(did, params.url, {
          title: params.title,
          excerpt: params.excerpt,
        });
        applyOptimisticLatrSaveInsert(qc, row);
      } catch {
        restoreLatrSaveQueries(qc, snapshot);
        return undefined;
      }
      return snapshot;
    },
    onError: (_error, _params, context) => {
      restoreLatrSaveQueries(qc, context);
    },
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

export function useDeleteLatrSaveMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (itemRkey: string) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.deleteSaveItem(itemRkey);
    },
    onMutate: async (itemRkey) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      applyOptimisticLatrSaveDelete(qc, itemRkey);
      return snapshot;
    },
    onError: (_error, _params, context) => {
      restoreLatrSaveQueries(qc, context);
    },
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

export function useArchiveLatrSaveMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (itemRkey: string) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.archiveSaveItem(itemRkey);
    },
    onMutate: async (itemRkey) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      applyOptimisticLatrSaveArchive(qc, itemRkey);
      return snapshot;
    },
    onError: (_error, _params, context) => {
      restoreLatrSaveQueries(qc, context);
    },
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

export function useUnarchiveLatrSaveMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (itemRkey: string) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.unarchiveSaveItem(itemRkey);
    },
    onMutate: async (itemRkey) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      applyOptimisticLatrSaveUnarchive(qc, itemRkey);
      return snapshot;
    },
    onError: (_error, _params, context) => {
      restoreLatrSaveQueries(qc, context);
    },
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

/** @deprecated Prefer useDeleteLatrSaveMutation. */
export function useDeleteHttpsReadLaterMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (normalizedUrl: string) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.deleteHttpsUrl(normalizedUrl);
    },
    onMutate: async (normalizedUrl) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      const active = qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY);
      const archived = qc.getQueryData<MergedLatrSave[]>(LATR_ARCHIVED_QUERY_KEY);
      const normalized = normalizeLatrHttpsUrl(normalizedUrl.trim());
      const row =
        active?.find(
          (entry) => entry.kind === "external" && entry.normalizedUrl === normalized
        ) ??
        archived?.find(
          (entry) => entry.kind === "external" && entry.normalizedUrl === normalized
        );
      if (row) {
        applyOptimisticLatrSaveDelete(qc, row.itemRkey);
      }
      return snapshot;
    },
    onError: (_error, _params, context) => {
      restoreLatrSaveQueries(qc, context);
    },
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

/** @deprecated Prefer useArchiveLatrSaveMutation. */
export function useArchiveHttpsReadLaterMutation() {
  const provider = useReadLaterProvider();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (normalizedUrl: string) => {
      if (!provider) throw new Error("No read-later provider — not signed in");
      return provider.archiveHttpsUrl(normalizedUrl);
    },
    onMutate: async (normalizedUrl) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      const active = qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY);
      const normalized = normalizeLatrHttpsUrl(normalizedUrl.trim());
      const row = active?.find(
        (entry) => entry.kind === "external" && entry.normalizedUrl === normalized
      );
      if (row) {
        applyOptimisticLatrSaveArchive(qc, row.itemRkey);
      }
      return snapshot;
    },
    onError: (_error, _params, context) => {
      restoreLatrSaveQueries(qc, context);
    },
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

export function useSaveReadLaterEntryMutation() {
  const provider = useReadLaterProvider();
  const { session, getOAuthSession } = useAuth();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (params: {
      entryId: string;
      url?: string;
      title?: string;
      excerpt?: string;
    }) => {
      if (!provider) throw new Error("No read-later provider — not signed in");

      const target = resolveReadLaterSaveTarget(params);
      const saveOptions = {
        title: target.title,
        excerpt: target.excerpt,
      };

      if (target.kind === "external") {
        return provider.saveHttpsUrl(target.url, saveOptions);
      }

      let linkedWebUrl = target.linkedWebUrl;
      if (!linkedWebUrl) {
        const oauthSession = getOAuthSession();
        const preview = oauthSession
          ? await resolveNativeSavedSubjectPreview(target.subjectUri, oauthSession)
          : null;
        linkedWebUrl = preview?.url?.trim();
      }

      return provider.saveNativeSubject(target.subjectUri, linkedWebUrl);
    },
    onMutate: async (params) => {
      const did = session?.did;
      if (!did) return undefined;

      const snapshot = await snapshotLatrSaveQueries(qc);
      const target = resolveReadLaterSaveTarget(params);
      try {
        const row =
          target.kind === "external"
            ? await buildOptimisticExternalLatrSave(did, target.url, {
                title: target.title,
                excerpt: target.excerpt,
              })
            : await buildOptimisticNativeLatrSave(did, target.subjectUri, {
                title: target.title,
                excerpt: target.excerpt,
                linkedWebUrl: target.linkedWebUrl,
              });
        applyOptimisticLatrSaveInsert(qc, row);
      } catch {
        restoreLatrSaveQueries(qc, snapshot);
        return undefined;
      }
      return snapshot;
    },
    onError: (_error, _params, context) => {
      restoreLatrSaveQueries(qc, context);
    },
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

/**
 * Whether an entry is already in the active read-later list (HTTPS URL or native subject).
 */
export function useEntryIsLatrSaved(
  entryId: string,
  displayUrlHttps?: string | null
): boolean {
  const { data: merged } = useLatrMergedHttpsSaves("active");
  const normalizedUrl = displayUrlHttps?.trim()
    ? normalizeLatrHttpsUrl(displayUrlHttps)
    : null;
  return useMemo(() => {
    if (!merged?.length) return false;
    return merged.some((row) => {
      if (row.kind === "native" && row.subjectUri === entryId) return true;
      if (
        row.kind === "external" &&
        normalizedUrl &&
        row.normalizedUrl === normalizedUrl
      ) {
        return true;
      }
      return false;
    });
  }, [entryId, merged, normalizedUrl]);
}

/**
 * Client-only: whether merged read-later rows already include this HTTPS URL string.
 */
export function useHttpsUrlIsLatrSaved(displayUrlHttps: string | null | undefined): boolean {
  const { data: merged } = useLatrMergedHttpsSaves("active");
  const n = displayUrlHttps?.trim()
    ? normalizeLatrHttpsUrl(displayUrlHttps)
    : null;
  return useMemo(() => {
    if (!n || !merged?.length) return false;
    return merged.some((row) => row.kind === "external" && row.normalizedUrl === n);
  }, [n, merged]);
}
