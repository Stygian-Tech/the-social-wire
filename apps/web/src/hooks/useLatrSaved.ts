"use client";

import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import {
  LATR_BOOKMARK_CONTRACT_VERSION,
  LatrBookmarksClient,
  migrateLegacyBookmarks,
} from "@/lib/latrBookmarks";
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
import { buildOptimisticBookmarkRow } from "@/lib/optimisticLatrSaves";
import { normalizeLatrHttpsUrl } from "@/lib/latrSavedUrls";
import { createReadLaterProvider } from "@/lib/readLaterProvider";
import { resolveReadLaterSaveTarget } from "@/lib/readLaterSaveTarget";
import {
  dummyLatrSavesForState,
  isDummyReaderDataEnabled,
} from "@/lib/dummyReaderData";
import { useAuth } from "./useAuth";
import { usePDSClient } from "./usePDSClient";

export { LATR_ARCHIVED_QUERY_KEY, LATR_SAVED_QUERY_KEY };

const MIGRATION_QUERY_KEY = "latrBookmarkMigration";

function migrationStorageKey(did: string): string {
  return `the-social-wire.latr-migration.${LATR_BOOKMARK_CONTRACT_VERSION}.${did}`;
}

function useReadLaterClients() {
  const pdsClient = usePDSClient();
  const { session, getOAuthSession } = useAuth();
  return useMemo(() => {
    if (!pdsClient || !session) return null;
    const oauthSession = getOAuthSession();
    if (!oauthSession) return null;
    return {
      did: session.did,
      bookmarks: new LatrBookmarksClient(oauthSession),
      provider: createReadLaterProvider(oauthSession, pdsClient, session.did),
    };
  }, [getOAuthSession, pdsClient, session]);
}

function latrSavesQueryKey(state: LatrSaveListState) {
  return state === "archived" ? LATR_ARCHIVED_QUERY_KEY : LATR_SAVED_QUERY_KEY;
}

export function useLatrMergedHttpsSaves(
  state: LatrSaveListState = "active",
  options?: { enabled?: boolean }
) {
  const clients = useReadLaterClients();
  const dummyReaderDataEnabled = isDummyReaderDataEnabled();
  const enabled = options?.enabled ?? true;
  const migration = useQuery({
    queryKey: [MIGRATION_QUERY_KEY, clients?.did, LATR_BOOKMARK_CONTRACT_VERSION],
    queryFn: async () => {
      if (!clients || typeof window === "undefined") return null;
      const key = migrationStorageKey(clients.did);
      if (window.localStorage.getItem(key) === "complete") return null;
      const summary = await migrateLegacyBookmarks(clients.bookmarks);
      if (!summary.hasConflicts) window.localStorage.setItem(key, "complete");
      return summary;
    },
    enabled: enabled && !dummyReaderDataEnabled && Boolean(clients),
    retry: false,
    staleTime: Infinity,
  });
  const listQuery = useQuery({
    queryKey: latrSavesQueryKey(state),
    queryFn: async (): Promise<MergedLatrSave[]> => {
      if (dummyReaderDataEnabled) return dummyLatrSavesForState(state);
      return clients?.bookmarks.listAll(state) ?? [];
    },
    enabled:
      enabled &&
      (dummyReaderDataEnabled || (Boolean(clients) && migration.isSuccess)),
    staleTime: 15_000,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
  return {
    ...listQuery,
    isLoading: migration.isLoading || listQuery.isLoading,
    isError: migration.isError || listQuery.isError,
    error: migration.error ?? listQuery.error,
    migrationWarning: migration.data?.hasConflicts
      ? `${migration.data.skippedConflict} legacy bookmark conflict${migration.data.skippedConflict === 1 ? " was" : "s were"} left unchanged and will be retried later.`
      : null,
  };
}

export function useSaveHttpsReadLaterMutation() {
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  const dummy = isDummyReaderDataEnabled();
  return useMutation({
    mutationFn: async (params: { url: string; title?: string; excerpt?: string }) => {
      if (dummy) return;
      if (!clients) throw new Error("No read-later provider — not signed in");
      await clients.provider.saveSubject(params.url.trim());
    },
    onMutate: async (params) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      applyOptimisticLatrSaveInsert(qc, buildOptimisticBookmarkRow(params.url, params));
      return snapshot;
    },
    onError: (_error, _params, context) => restoreLatrSaveQueries(qc, context),
    onSettled: () => { if (!dummy) invalidateLatrSaveQueries(qc); },
  });
}

function useBookmarkMutation(action: "delete" | "archive" | "unarchive") {
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  const dummy = isDummyReaderDataEnabled();
  return useMutation({
    mutationFn: async (bookmarkUri: string) => {
      if (dummy) return;
      if (!clients) throw new Error("No read-later provider — not signed in");
      if (action === "delete") return clients.provider.deleteSaveItem(bookmarkUri);
      if (action === "archive") return clients.provider.archiveSaveItem(bookmarkUri);
      return clients.provider.unarchiveSaveItem(bookmarkUri);
    },
    onMutate: async (bookmarkUri) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      if (action === "delete") applyOptimisticLatrSaveDelete(qc, bookmarkUri);
      else if (action === "archive") applyOptimisticLatrSaveArchive(qc, bookmarkUri);
      else applyOptimisticLatrSaveUnarchive(qc, bookmarkUri);
      return snapshot;
    },
    onError: (_error, _params, context) => restoreLatrSaveQueries(qc, context),
    onSettled: () => { if (!dummy) invalidateLatrSaveQueries(qc); },
  });
}

export function useDeleteLatrSaveMutation() {
  return useBookmarkMutation("delete");
}

export function useArchiveLatrSaveMutation() {
  return useBookmarkMutation("archive");
}

export function useUnarchiveLatrSaveMutation() {
  return useBookmarkMutation("unarchive");
}

/** @deprecated Prefer useDeleteLatrSaveMutation. */
export function useDeleteHttpsReadLaterMutation() {
  const mutation = useDeleteLatrSaveMutation();
  const qc = useQueryClient();
  return {
    ...mutation,
    mutate: (url: string) => {
      const normalized = normalizeLatrHttpsUrl(url);
      const rows = [
        ...(qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY) ?? []),
        ...(qc.getQueryData<MergedLatrSave[]>(LATR_ARCHIVED_QUERY_KEY) ?? []),
      ];
      const row = rows.find(
        (candidate) => candidate.kind === "external" && candidate.normalizedUrl === normalized
      );
      if (row) mutation.mutate(row.itemRkey);
    },
  };
}

/** @deprecated Prefer useArchiveLatrSaveMutation. */
export function useArchiveHttpsReadLaterMutation() {
  const mutation = useArchiveLatrSaveMutation();
  const qc = useQueryClient();
  return {
    ...mutation,
    mutate: (url: string) => {
      const normalized = normalizeLatrHttpsUrl(url);
      const rows = qc.getQueryData<MergedLatrSave[]>(LATR_SAVED_QUERY_KEY) ?? [];
      const row = rows.find(
        (candidate) => candidate.kind === "external" && candidate.normalizedUrl === normalized
      );
      if (row) mutation.mutate(row.itemRkey);
    },
  };
}

export function useSaveReadLaterEntryMutation() {
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: {
      entryId: string;
      url?: string;
      title?: string;
      excerpt?: string;
    }) => {
      if (!clients) throw new Error("No read-later provider — not signed in");
      const target = resolveReadLaterSaveTarget(params);
      if (!target.subject) throw new Error("Cannot save an empty bookmark subject");
      await clients.provider.saveSubject(target.subject);
    },
    onMutate: async (params) => {
      const snapshot = await snapshotLatrSaveQueries(qc);
      const target = resolveReadLaterSaveTarget(params);
      applyOptimisticLatrSaveInsert(qc, buildOptimisticBookmarkRow(target.subject, target));
      return snapshot;
    },
    onError: (_error, _params, context) => restoreLatrSaveQueries(qc, context),
    onSettled: () => invalidateLatrSaveQueries(qc),
  });
}

export function useEntryIsLatrSaved(
  entryId: string,
  displayUrlHttps?: string | null
): boolean {
  const { data } = useLatrMergedHttpsSaves("active");
  const subject = displayUrlHttps?.trim() || entryId.trim();
  return useMemo(
    () => Boolean(subject && data?.some((row) => row.subjectUri === subject)),
    [data, subject]
  );
}

export function useHttpsUrlIsLatrSaved(
  displayUrlHttps: string | null | undefined
): boolean {
  const { data } = useLatrMergedHttpsSaves("active");
  const subject = displayUrlHttps?.trim();
  return useMemo(
    () => Boolean(subject && data?.some((row) => row.subjectUri === subject)),
    [data, subject]
  );
}
