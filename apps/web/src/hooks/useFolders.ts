"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { type FolderRecord, rkeyFromURI } from "@/lib/pdsClient";
import {
  addOptimisticFolderToProjection,
  createOptimisticFolderRkey,
  removeFolderFromSidebarProjection,
  removeOptimisticFolderFromProjection,
  replaceOptimisticFolderInProjection,
} from "@/lib/optimisticSidebarFolder";
import { migrateStoredSidebarFolderExpandKey } from "@/lib/sidebarExpandedKeysStorage";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { useAuth } from "./useAuth";
import { usePDSClient } from "./usePDSClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "./usePublicationSidebarData";

export const FOLDERS_QUERY_KEY = ["folders"] as const;

type CreateFolderParams = {
  name: string;
  icon?: string;
  iconImage?: string;
};

type CreateFolderContext = {
  previousProjection: PublicationSidebarProjection | undefined;
  optimisticRkey: string;
};

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
          $type: "app.thesocialwire.folder" as const,
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
 * Folder mutations write directly to the viewer PDS (OAuth DPoP). Reads come from
 * the sidebar projection query.
 */
export function useCreateFolder() {
  const client = usePDSClient();
  const { session } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: CreateFolderParams) => {
      if (!client) throw new Error("Sign in to create folders on your PDS.");
      const created = await client.createFolder(params.name, {
        icon: params.icon,
        iconImage: params.iconImage,
      });
      return {
        uri: created.uri,
        rkey: rkeyFromURI(created.uri),
      };
    },
    onMutate: async (params): Promise<CreateFolderContext | undefined> => {
      const did = session?.did;
      if (!did) return undefined;

      const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
      await qc.cancelQueries({ queryKey });

      const previousProjection =
        qc.getQueryData<PublicationSidebarProjection>(queryKey);
      if (!previousProjection) return undefined;

      const optimisticRkey = createOptimisticFolderRkey();
      const nextProjection = addOptimisticFolderToProjection(
        previousProjection,
        {
          viewerDid: did,
          rkey: optimisticRkey,
          name: params.name,
          icon: params.icon,
          iconImage: params.iconImage,
        }
      );
      if (nextProjection) {
        qc.setQueryData(queryKey, nextProjection);
      }

      return { previousProjection, optimisticRkey };
    },
    onError: (_error, _params, context) => {
      const did = session?.did;
      if (!did || !context?.optimisticRkey) return;

      const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
      qc.setQueryData<PublicationSidebarProjection>(queryKey, (current) => {
        if (!current) return context.previousProjection;
        return (
          removeOptimisticFolderFromProjection(
            current,
            context.optimisticRkey
          ) ?? context.previousProjection
        );
      });
    },
    onSuccess: (created, params, context) => {
      const did = session?.did;
      if (!did) return;

      const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
      if (!context?.optimisticRkey) {
        qc.invalidateQueries({ queryKey });
        return;
      }

      qc.setQueryData<PublicationSidebarProjection>(queryKey, (current) =>
        replaceOptimisticFolderInProjection(
          current,
          context.optimisticRkey,
          created,
          params
        )
      );
      if (typeof window !== "undefined") {
        migrateStoredSidebarFolderExpandKey(
          window.localStorage,
          did,
          context.optimisticRkey,
          created.rkey
        );
      }
    },
  });
}

export function useUpdateFolder() {
  const client = usePDSClient();
  const { session } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (params: {
      uri: string;
      updates: Partial<Pick<FolderRecord, "name" | "sortOrder" | "icon" | "iconImage">>;
    }) => {
      if (!client) throw new Error("Sign in to update folders on your PDS.");
      const rkey = rkeyFromURI(params.uri);
      await client.updateFolder(rkey, params.updates);
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
  const client = usePDSClient();
  const { session } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (uri: string) => {
      if (!client) throw new Error("Sign in to delete folders on your PDS.");
      const rkey = rkeyFromURI(uri);
      await client.deleteFolder(rkey);
      return { uri, rkey };
    },
    onMutate: async (uri) => {
      const did = session?.did;
      if (!did) return undefined;

      const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
      await qc.cancelQueries({ queryKey });

      const previousProjection =
        qc.getQueryData<PublicationSidebarProjection>(queryKey);
      if (!previousProjection) return undefined;

      const folderRkey = rkeyFromURI(uri);
      const nextProjection = removeFolderFromSidebarProjection(
        previousProjection,
        folderRkey
      );
      if (nextProjection) {
        qc.setQueryData(queryKey, nextProjection);
      }

      return { previousProjection };
    },
    onError: (_error, _uri, context) => {
      const did = session?.did;
      if (!did || !context?.previousProjection) return;
      qc.setQueryData(
        PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
        context.previousProjection
      );
    },
  });
}
