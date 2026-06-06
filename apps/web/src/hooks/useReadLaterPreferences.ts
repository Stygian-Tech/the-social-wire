"use client";

import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "./useAuth";
import type { PreferencesRecord, RepoRecord } from "@/lib/pdsClient";
import { fetchSyncPreferences } from "@/lib/syncPreferencesClient";
import { findReadLaterService } from "@/lib/readLaterServices";

export const ACCOUNT_PREFERENCES_QUERY_KEY = ["accountPreferences"] as const;

const DEFAULT_READ_LATER_SERVICE_ID = "latr-link" as const;

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

/** L@tr Link is the only supported read-later provider for now. */
export function useConfiguredReadLaterService() {
  const prefs = useAccountPreferences();

  return useMemo(
    () => ({
      isLoading: prefs.isLoading,
      data: prefs.data as RepoRecord<PreferencesRecord> | null | undefined,
      serviceId: DEFAULT_READ_LATER_SERVICE_ID,
      service: findReadLaterService(DEFAULT_READ_LATER_SERVICE_ID),
    }),
    [prefs.isLoading, prefs.data]
  );
}
