"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { type FolderRecord, rkeyFromURI } from "@/lib/pdsClient";
import {
  createFolderOnGateway,
  deleteFolderOnGateway,
  updateFolderOnGateway,
} from "@/lib/publicationProjectionClient";
import { useAuth } from "./useAuth";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "./usePublicationSidebarData";

export const FOLDERS_QUERY_KEY = ["folders"] as const;

export type FolderRecordFromProjection = {
  uri: string;
  cid: string;
  value: FolderRecord;
};

/** Reads folders from the gateway sidebar projection (no direct PDS list). */
export function useFolders() {
  const { session, getOAuthSession } = useAuth();
  return useQuery({
    queryKey: [...FOLDERS_QUERY_KEY, session?.did ?? ""] as const,
    queryFn: async () => {
      const oauth = getOAuthSession();
      if (!oauth) return [] as FolderRecordFromProjection[];
      const { fetchPublicationSidebar } = await import(
        "@/lib/publicationProjectionClient"
      );
      const projection = await fetchPublicationSidebar(oauth, { phase: "priority" });
      return projection.folders.map((folder) => ({
        uri: folder.uri,
        cid: "",
        value: {
          $type: "com.thesocialwire.folder" as const,
          name: String(folder.value.name ?? folder.rkey),
          sortOrder:
            typeof folder.value.sortOrder === "number"
              ? folder.value.sortOrder
              : 0,
          icon:
            typeof folder.value.icon === "string" ? folder.value.icon : undefined,
          iconImage:
            typeof folder.value.iconImage === "string"
              ? folder.value.iconImage
              : undefined,
          createdAt:
            typeof folder.value.createdAt === "string"
              ? folder.value.createdAt
              : new Date().toISOString(),
        },
      }));
    },
    enabled: !!session,
    staleTime: 30_000,
  });
}

/**
 * Folder mutations go through the gateway (canonical PDS write-through).
 * Folder reads come from the sidebar projection query.
 */
export function useCreateFolder() {
  const { session, getOAuthSession } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: {
      name: string;
      icon?: string;
      iconImage?: string;
    }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      return createFolderOnGateway(oauth, {
        name: params.name,
        icon: params.icon,
        iconImage: params.iconImage,
      });
    },
    onSuccess: () => {
      if (session?.did) {
        qc.invalidateQueries({
          queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(session.did),
        });
      }
    },
  });
}

export function useUpdateFolder() {
  const { session, getOAuthSession } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: {
      uri: string;
      updates: Partial<Pick<FolderRecord, "name" | "sortOrder" | "icon" | "iconImage">>;
    }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const rkey = rkeyFromURI(params.uri);
      await updateFolderOnGateway(oauth, rkey, {
        name: params.updates.name,
        sortOrder: params.updates.sortOrder,
        icon: params.updates.icon,
        iconImage: params.updates.iconImage,
      });
    },
    onSuccess: () => {
      if (session?.did) {
        qc.invalidateQueries({
          queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(session.did),
        });
      }
    },
  });
}

export function useDeleteFolder() {
  const { session, getOAuthSession } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (uri: string) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const rkey = rkeyFromURI(uri);
      await deleteFolderOnGateway(oauth, rkey);
    },
    onSuccess: () => {
      if (session?.did) {
        qc.invalidateQueries({
          queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(session.did),
        });
      }
    },
  });
}
