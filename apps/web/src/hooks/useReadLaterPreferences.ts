"use client";

import { useEffect, useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { usePDSClient } from "./usePDSClient";
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
  const client = usePDSClient();
  return useQuery({
    queryKey: ACCOUNT_PREFERENCES_QUERY_KEY,
    queryFn: async () => {
      if (!client) return null;
      return client.getPreferences();
    },
    enabled: !!client,
    staleTime: 30_000,
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
      return client.upsertPreferences({ readLaterService: serviceId });
    },
    onSuccess: () =>
      qc.invalidateQueries({ queryKey: ACCOUNT_PREFERENCES_QUERY_KEY }),
  });
}
