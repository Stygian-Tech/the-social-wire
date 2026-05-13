"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { usePDSClient } from "./usePDSClient";
import { useAuth } from "./useAuth";
import {
  discoverPublications,
  type DiscoveredPublication,
} from "@/lib/atprotoClient";

export type { DiscoveredPublication };

export const PUB_PREFS_QUERY_KEY = ["publicationPrefs"] as const;
export const DISCOVERY_QUERY_KEY = (did: string) =>
  ["discovery", did] as const;

// ── Publication prefs ─────────────────────────────────────────────────────────

/**
 * Returns the user's publication preferences from their PDS.
 */
export function usePublicationPrefs() {
  const client = usePDSClient();
  return useQuery({
    queryKey: PUB_PREFS_QUERY_KEY,
    queryFn: () => client!.listPublicationPrefs(),
    enabled: !!client,
    staleTime: 30_000,
  });
}

// ── Discovery ─────────────────────────────────────────────────────────────────

/**
 * Returns all publications discovered from the user's follow graph.
 */
export function useDiscovery() {
  const { session } = useAuth();
  const did = session?.did ?? null;

  return useQuery({
    queryKey: DISCOVERY_QUERY_KEY(did ?? ""),
    queryFn: async (): Promise<DiscoveredPublication[]> => {
      if (!did || !session) return [];
      return discoverPublications(did, session);
    },
    enabled: !!did && !!session,
    staleTime: 5 * 60_000, // 5 minutes
  });
}

/**
 * Re-runs discovery by invalidating the cached results, triggering a fresh fetch.
 */
export function useRefreshDiscovery() {
  const { session } = useAuth();
  const did = session?.did ?? null;
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (): Promise<DiscoveredPublication[]> => {
      if (!did || !session) throw new Error("Not authenticated");
      return discoverPublications(did, session);
    },
    onSuccess: (publications) => {
      // Populate the query cache directly with fresh results — no extra round-trip.
      if (did) {
        qc.setQueryData(DISCOVERY_QUERY_KEY(did), publications);
      }
    },
  });
}

// ── Publication prefs mutations ───────────────────────────────────────────────

export function useSetPublicationFolder() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({
      publicationId,
      folderId,
      existingRkey,
    }: {
      publicationId: string;
      folderId: string | null;
      existingRkey?: string;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      return client.upsertPublicationPrefs(
        publicationId,
        { folderId: folderId ?? undefined },
        existingRkey
      );
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: PUB_PREFS_QUERY_KEY }),
  });
}

export function useHidePublication() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({
      publicationId,
      hidden,
      existingRkey,
    }: {
      publicationId: string;
      hidden: boolean;
      existingRkey?: string;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      return client.upsertPublicationPrefs(
        publicationId,
        { hidden },
        existingRkey
      );
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: PUB_PREFS_QUERY_KEY }),
  });
}
