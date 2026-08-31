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
  applyOptimisticLatrSaveTags,
  applyOptimisticLatrSaveUnarchive,
  invalidateLatrSaveQueries,
  LATR_ARCHIVED_QUERY_KEY,
  LATR_SAVED_QUERY_KEY,
  LEGACY_LATR_SAVE_QUERY_KEYS,
  restoreLatrSaveQueries,
  scopedLatrSaveQueryKeys,
  snapshotLatrSaveQueries,
} from "@/lib/latrSavedMutations";
import { LATR_TAG_PAGE_LIMIT, normalizeLatrTags } from "@/lib/latrTags";
import type { LatrTagCount, LatrTagMutationResult } from "latr-packages/gateway-client";
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
import { readLaterQueryKeys } from "@/lib/semble";
import { normalizeSembleUrl } from "@/lib/semble";
import { useConfiguredReadLaterService } from "./useReadLaterPreferences";
import {
  useSembleCollectionItems,
  useSembleWriter,
} from "./useSembleReadLater";

export { LATR_ARCHIVED_QUERY_KEY, LATR_SAVED_QUERY_KEY };

const MIGRATION_QUERY_KEY = "latrBookmarkMigration";
export const LATR_TAGS_QUERY_KEY = ["latrTags"] as const;

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
      saveKeys: scopedLatrSaveQueryKeys(session.did),
      tagsKey: [...readLaterQueryKeys.root(session.did, "latr-gateway"), "tags"] as const,
    };
  }, [getOAuthSession, pdsClient, session]);
}

function latrSavesQueryKey(
  state: LatrSaveListState,
  clients: ReturnType<typeof useReadLaterClients>,
) {
  const keys = clients?.saveKeys ?? LEGACY_LATR_SAVE_QUERY_KEYS;
  return state === "archived" ? keys.archived : keys.active;
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
    queryKey: latrSavesQueryKey(state, clients),
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

export function useLatrTags() {
  const clients = useReadLaterClients();
  return useQuery({
    queryKey: clients?.tagsKey ?? LATR_TAGS_QUERY_KEY,
    queryFn: async (): Promise<LatrTagCount[]> => {
      if (!clients) return [];
      const counts = new Map<string, number>();
      let cursor: string | undefined;
      do {
        const page = await clients.provider.listTags(cursor);
        for (const item of page.tagCounts) {
          counts.set(item.tag, (counts.get(item.tag) ?? 0) + item.count);
        }
        cursor = page.cursor?.trim() || undefined;
      } while (cursor);
      return [...counts.entries()]
        .map(([tag, count]) => ({ tag, count }))
        .sort((left, right) => left.tag.localeCompare(right.tag));
    },
    enabled: Boolean(clients),
    staleTime: 15_000,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
}

export function useSaveHttpsReadLaterMutation() {
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  const dummy = isDummyReaderDataEnabled();
  return useMutation({
    mutationFn: async (params: { url: string; title?: string; excerpt?: string; tags?: string[] }) => {
      if (dummy) return;
      if (!clients) throw new Error("No read-later provider — not signed in");
      await clients.provider.saveSubject(params.url.trim(), normalizeLatrTags(params.tags ?? []));
    },
    onMutate: async (params) => {
      const keys = clients?.saveKeys ?? LEGACY_LATR_SAVE_QUERY_KEYS;
      const snapshot = await snapshotLatrSaveQueries(qc, keys);
      applyOptimisticLatrSaveInsert(qc, buildOptimisticBookmarkRow(params.url, params), keys);
      return snapshot;
    },
    onError: (_error, _params, context) =>
      restoreLatrSaveQueries(qc, context, clients?.saveKeys),
    onSettled: () => {
      if (!dummy) invalidateLatrSaveQueries(qc, clients?.saveKeys);
      void qc.invalidateQueries({ queryKey: clients?.tagsKey ?? LATR_TAGS_QUERY_KEY });
    },
  });
}

export function useSetLatrSaveTagsMutation() {
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: { bookmarkUri: string; tags: string[] }) => {
      if (!clients) throw new Error("No read-later provider — not signed in");
      const tags = normalizeLatrTags(params.tags);
      await clients.provider.setSaveItemTags(params.bookmarkUri, tags);
      return { ...params, tags };
    },
    onMutate: async ({ bookmarkUri, tags }) => {
      const keys = clients?.saveKeys ?? LEGACY_LATR_SAVE_QUERY_KEYS;
      const snapshot = await snapshotLatrSaveQueries(qc, keys);
      applyOptimisticLatrSaveTags(qc, bookmarkUri, normalizeLatrTags(tags), keys);
      return snapshot;
    },
    onError: (_error, _params, context) =>
      restoreLatrSaveQueries(qc, context, clients?.saveKeys),
    onSettled: () => {
      invalidateLatrSaveQueries(qc, clients?.saveKeys);
      void qc.invalidateQueries({ queryKey: clients?.tagsKey ?? LATR_TAGS_QUERY_KEY });
    },
  });
}

type LatrTagPageInput = {
  tag: string;
  replacement?: string;
  cursor?: string;
};

function useLatrTagPageMutation(action: "rename" | "delete") {
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  return useMutation<LatrTagMutationResult, Error, LatrTagPageInput>({
    mutationFn: async ({ tag, replacement, cursor }) => {
      if (!clients) throw new Error("No read-later provider — not signed in");
      if (action === "rename") {
        const next = replacement?.trim();
        if (!next) throw new Error("Enter a replacement tag.");
        const result = await clients.provider.renameTagPage({
          tag,
          replacement: next,
          cursor,
          limit: LATR_TAG_PAGE_LIMIT,
        });
        return result;
      }
      const result = await clients.provider.deleteTagPage({
        tag,
        cursor,
        limit: LATR_TAG_PAGE_LIMIT,
      });
      return result;
    },
    onSettled: () => {
      invalidateLatrSaveQueries(qc, clients?.saveKeys);
      void qc.invalidateQueries({ queryKey: clients?.tagsKey ?? LATR_TAGS_QUERY_KEY });
    },
  });
}

export function useRenameLatrTagPageMutation() {
  return useLatrTagPageMutation("rename");
}

export function useDeleteLatrTagPageMutation() {
  return useLatrTagPageMutation("delete");
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
      const keys = clients?.saveKeys ?? LEGACY_LATR_SAVE_QUERY_KEYS;
      const snapshot = await snapshotLatrSaveQueries(qc, keys);
      if (action === "delete") applyOptimisticLatrSaveDelete(qc, bookmarkUri, keys);
      else if (action === "archive") applyOptimisticLatrSaveArchive(qc, bookmarkUri, keys);
      else applyOptimisticLatrSaveUnarchive(qc, bookmarkUri, keys);
      return snapshot;
    },
    onError: (_error, _params, context) =>
      restoreLatrSaveQueries(qc, context, clients?.saveKeys),
    onSettled: () => {
      if (!dummy) invalidateLatrSaveQueries(qc, clients?.saveKeys);
    },
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
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  return {
    ...mutation,
    mutate: (url: string) => {
      const normalized = normalizeLatrHttpsUrl(url);
      const rows = [
        ...(qc.getQueryData<MergedLatrSave[]>(clients?.saveKeys.active ?? LATR_SAVED_QUERY_KEY) ?? []),
        ...(qc.getQueryData<MergedLatrSave[]>(clients?.saveKeys.archived ?? LATR_ARCHIVED_QUERY_KEY) ?? []),
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
  const clients = useReadLaterClients();
  const qc = useQueryClient();
  return {
    ...mutation,
    mutate: (url: string) => {
      const normalized = normalizeLatrHttpsUrl(url);
      const rows = qc.getQueryData<MergedLatrSave[]>(clients?.saveKeys.active ?? LATR_SAVED_QUERY_KEY) ?? [];
      const row = rows.find(
        (candidate) => candidate.kind === "external" && candidate.normalizedUrl === normalized
      );
      if (row) mutation.mutate(row.itemRkey);
    },
  };
}

export function useSaveReadLaterEntryMutation() {
  const clients = useReadLaterClients();
  const sembleWriter = useSembleWriter();
  const configured = useConfiguredReadLaterService();
  const sembleCollectionUri =
    configured.sembleConnection?.collectionUri?.trim() ?? "";
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: {
      entryId: string;
      url?: string;
      title?: string;
      excerpt?: string;
      tags?: string[];
    }) => {
      const target = resolveReadLaterSaveTarget(params);
      if (!target.subject) throw new Error("Cannot save an empty bookmark subject");
      if (configured.serviceId === "semble") {
        if (!sembleWriter || !sembleCollectionUri) {
          throw new Error("Choose a Semble collection in Your Account settings.");
        }
        const url = normalizeSembleUrl(params.url ?? target.subject);
        if (!url) {
          throw new Error("This item has no public URL that Semble can save.");
        }
        await sembleWriter.saveUrl({ collectionUri: sembleCollectionUri, url });
        return;
      }
      if (!clients) throw new Error("No read-later provider — not signed in");
      await clients.provider.saveSubject(target.subject, normalizeLatrTags(params.tags ?? []));
    },
    onMutate: async (params) => {
      if (configured.serviceId === "semble") {
        return { provider: "semble" as const, snapshot: undefined };
      }
      const keys = clients?.saveKeys ?? LEGACY_LATR_SAVE_QUERY_KEYS;
      const snapshot = await snapshotLatrSaveQueries(qc, keys);
      const target = resolveReadLaterSaveTarget(params);
      applyOptimisticLatrSaveInsert(
        qc,
        buildOptimisticBookmarkRow(target.subject, { ...target, tags: params.tags }),
        keys,
      );
      return { provider: "latr-gateway" as const, snapshot };
    },
    onError: (_error, _params, context) => {
      if (context?.provider === "latr-gateway") {
        restoreLatrSaveQueries(qc, context.snapshot, clients?.saveKeys);
      }
    },
    onSettled: (_data, _error, _params, context) => {
      if (context?.provider === "semble") {
        const viewerDid = sembleWriter?.viewerDid;
        if (viewerDid && sembleCollectionUri) {
          void qc.invalidateQueries({
            queryKey: readLaterQueryKeys.collection(
              viewerDid,
              "semble",
              sembleCollectionUri,
            ),
          });
        }
        return;
      }
      invalidateLatrSaveQueries(qc, clients?.saveKeys);
      void qc.invalidateQueries({ queryKey: clients?.tagsKey ?? LATR_TAGS_QUERY_KEY });
    },
  });
}

export function useEntryIsLatrSaved(
  entryId: string,
  displayUrlHttps?: string | null
): boolean {
  const configured = useConfiguredReadLaterService();
  const usingSemble = configured.serviceId === "semble";
  const { data } = useLatrMergedHttpsSaves("active", { enabled: !usingSemble });
  const semble = useSembleCollectionItems(
    configured.sembleConnection?.collectionUri,
    { enabled: usingSemble },
  );
  const subject = displayUrlHttps?.trim() || entryId.trim();
  const normalizedSembleUrl = normalizeSembleUrl(subject);
  return useMemo(
    () =>
      usingSemble
        ? Boolean(
            normalizedSembleUrl &&
              semble.items.some(
                (item) => normalizeSembleUrl(item.url ?? "") === normalizedSembleUrl,
              ),
          )
        : Boolean(subject && data?.some((row) => row.subjectUri === subject)),
    [data, normalizedSembleUrl, semble.items, subject, usingSemble],
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
