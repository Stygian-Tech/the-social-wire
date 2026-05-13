"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { type FolderRecord, rkeyFromURI } from "@/lib/pdsClient";
import { usePDSClient } from "./usePDSClient";

export const FOLDERS_QUERY_KEY = ["folders"] as const;

/**
 * Returns the user's folders from their PDS, sorted by sortOrder.
 */
export function useFolders() {
  const client = usePDSClient();
  return useQuery({
    queryKey: FOLDERS_QUERY_KEY,
    queryFn: async () => {
      if (!client) return [];
      const records = await client.listFolders();
      return records.sort(
        (a, b) => (a.value.sortOrder ?? 0) - (b.value.sortOrder ?? 0)
      );
    },
    enabled: !!client,
    staleTime: 30_000,
  });
}

/**
 * Creates a new folder on the user's PDS.
 */
export function useCreateFolder() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: {
      name: string;
      icon?: string;
      iconImage?: string;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      return client.createFolder(params.name, {
        icon: params.icon,
        iconImage: params.iconImage,
      });
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: FOLDERS_QUERY_KEY }),
  });
}

/**
 * Renames (or updates) a folder.
 */
export function useUpdateFolder() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: {
      uri: string;
      updates: Partial<Pick<FolderRecord, "name" | "sortOrder" | "icon" | "iconImage">>;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      const rkey = rkeyFromURI(params.uri);
      return client.updateFolder(rkey, params.updates);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: FOLDERS_QUERY_KEY }),
  });
}

/**
 * Deletes a folder from the user's PDS.
 */
export function useDeleteFolder() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (uri: string) => {
      if (!client) throw new Error("No PDS client — not signed in");
      const rkey = rkeyFromURI(uri);
      return client.deleteFolder(rkey);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: FOLDERS_QUERY_KEY }),
  });
}
