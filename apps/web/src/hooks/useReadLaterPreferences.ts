"use client";

import { useEffect, useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "./useAuth";
import { usePDSClient } from "./usePDSClient";
import type { PreferencesRecord, RepoRecord } from "@/lib/pdsClient";
import { fetchSyncPreferences } from "@/lib/syncPreferencesClient";
import {
  findReadLaterService,
  READ_LATER_SERVICES,
  READ_LATER_SERVICE_STORAGE_KEY,
  type ReadLaterServiceId,
} from "@/lib/readLaterServices";

export const ACCOUNT_PREFERENCES_QUERY_KEY = ["accountPreferences"] as const;

function isReadLaterServiceId(value: string | null): value is ReadLaterServiceId {
  return READ_LATER_SERVICES.some((service) => service.id === value);
}

function readLocalConfiguredService(): ReadLaterServiceId {
  if (typeof window === "undefined") return "latr-link";
  const stored = window.localStorage.getItem(READ_LATER_SERVICE_STORAGE_KEY);
  return isReadLaterServiceId(stored) ? stored : "latr-link";
}

export function useAccountPreferences() {
  const { session, getOAuthSession } = useAuth();
  return useQuery({
    queryKey: ACCOUNT_PREFERENCES_QUERY_KEY,
    queryFn: async () => {
      const oauth = getOAuthSession();
      if (!oauth || !session) return null;
      return fetchSyncPreferences(oauth, session.did);
    },
    enabled: !!session,
    staleTime: 30_000,
    retry: 1,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
}

export function useConfiguredReadLaterService() {
  const prefs = useAccountPreferences();
  const pdsServiceId = prefs.data?.value.readLaterService ?? null;

  const serviceId = useMemo<ReadLaterServiceId>(() => {
    if (isReadLaterServiceId(pdsServiceId)) return pdsServiceId;
    return readLocalConfiguredService();
  }, [pdsServiceId]);

  useEffect(() => {
    if (!isReadLaterServiceId(pdsServiceId)) return;
    window.localStorage.setItem(READ_LATER_SERVICE_STORAGE_KEY, pdsServiceId);
  }, [pdsServiceId]);

  return useMemo(
    () => ({
      isLoading: prefs.isLoading,
      data: prefs.data,
      serviceId,
      service: findReadLaterService(serviceId),
    }),
    [prefs.isLoading, prefs.data, serviceId]
  );
}

export function useSetReadLaterServicePreference() {
  const client = usePDSClient();
  const qc = useQueryClient();

  return useMutation({
    onMutate: async (serviceId: ReadLaterServiceId) => {
      window.localStorage.setItem(READ_LATER_SERVICE_STORAGE_KEY, serviceId);
      const previous = qc.getQueryData(ACCOUNT_PREFERENCES_QUERY_KEY);
      qc.setQueryData(ACCOUNT_PREFERENCES_QUERY_KEY, {
        uri: "",
        cid: "",
        value: {
          $type: "com.thesocialwire.preferences",
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          readLaterService: serviceId,
        },
      });
      return { previous };
    },
    mutationFn: async (serviceId: ReadLaterServiceId) => {
      if (!client) {
        throw new Error("No PDS client — not signed in");
      }
      const existing = qc.getQueryData<RepoRecord<PreferencesRecord> | null>(
        ACCOUNT_PREFERENCES_QUERY_KEY
      );
      return client.upsertPreferences({ readLaterService: serviceId }, existing);
    },
    onSuccess: () =>
      qc.invalidateQueries({ queryKey: ACCOUNT_PREFERENCES_QUERY_KEY }),
    onError: (_error, _serviceId, context) => {
      if (context?.previous) {
        qc.setQueryData(ACCOUNT_PREFERENCES_QUERY_KEY, context.previous);
      }
    },
  });
}
