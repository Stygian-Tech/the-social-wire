"use client";

import { useMemo } from "react";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import {
  SEMBLE_PROVIDER_ID,
  readLaterQueryKeys,
  type SembleCollection,
  type SembleSavedItem,
} from "@/lib/semble";
import { SembleReadClient } from "@/lib/sembleClient";
import {
  SembleLinkCreationError,
  SemblePDSClient,
  type SembleStrongRef,
} from "@/lib/semblePdsClient";

function useSembleClients() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  return useMemo(() => {
    void oauthSessionReloadSeq;
    const oauthSession = getOAuthSession();
    if (!session || !oauthSession) return null;
    return {
      viewerDid: session.did,
      reader: new SembleReadClient(oauthSession),
      writer: new SemblePDSClient(oauthSession, session.did),
    };
  }, [getOAuthSession, oauthSessionReloadSeq, session]);
}

export function useSembleWriter() {
  return useSembleClients()?.writer ?? null;
}

export function useSembleCollections(options?: { enabled?: boolean }) {
  const clients = useSembleClients();
  const query = useInfiniteQuery({
    queryKey: readLaterQueryKeys.collections(clients?.viewerDid ?? "signed-out"),
    queryFn: ({ pageParam, signal }) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      return clients.reader.listCollections({ cursor: pageParam, signal });
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.cursor,
    enabled: (options?.enabled ?? true) && Boolean(clients),
    staleTime: 60_000,
    gcTime: 7 * 24 * 60 * 60_000,
    refetchOnWindowFocus: false,
    retry: 1,
  });
  const collections = useMemo(() => {
    const byUri = new Map<string, SembleCollection>();
    for (const page of query.data?.pages ?? []) {
      for (const collection of page.collections) byUri.set(collection.uri, collection);
    }
    return [...byUri.values()];
  }, [query.data?.pages]);
  return { ...query, collections };
}

export function useSembleCollectionItems(
  collectionUri: string | null | undefined,
  options?: { enabled?: boolean },
) {
  const clients = useSembleClients();
  const uri = collectionUri?.trim() ?? "";
  const query = useInfiniteQuery({
    queryKey: readLaterQueryKeys.items(
      clients?.viewerDid ?? "signed-out",
      SEMBLE_PROVIDER_ID,
      uri || "unconfigured",
    ),
    queryFn: ({ pageParam, signal }) => {
      if (!clients || !uri) throw new Error("Choose a Semble collection first.");
      return clients.reader.getCollection({
        collectionUri: uri,
        cursor: pageParam,
        signal,
      });
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.cursor,
    enabled: (options?.enabled ?? true) && Boolean(clients && uri),
    staleTime: 15_000,
    gcTime: 7 * 24 * 60 * 60_000,
    refetchOnWindowFocus: false,
    retry: 1,
  });
  const items = useMemo(() => {
    const byMembership = new Map<string, SembleSavedItem>();
    for (const page of query.data?.pages ?? []) {
      for (const item of page.items) {
        byMembership.set(item.membership?.linkUri ?? item.id, item);
      }
    }
    return [...byMembership.values()];
  }, [query.data?.pages]);
  return {
    ...query,
    items,
    collection: query.data?.pages[0]?.collection ?? null,
    membershipComplete:
      Boolean(query.data?.pages.length) &&
      (query.data?.pages.every((page) => page.membershipComplete) ?? false),
    recordLinksComplete:
      Boolean(query.data?.pages.length) &&
      (query.data?.pages.every((page) => page.recordLinksComplete) ?? false),
  };
}

function useInvalidateSembleCollection(collectionUri: string) {
  const { session } = useAuth();
  const queryClient = useQueryClient();
  return () => {
    if (!session) return;
    void queryClient.invalidateQueries({
      queryKey: readLaterQueryKeys.collection(
        session.did,
        SEMBLE_PROVIDER_ID,
        collectionUri,
      ),
    });
    void queryClient.invalidateQueries({
      queryKey: readLaterQueryKeys.collections(session.did),
    });
  };
}

export function useSaveToSembleMutation(collectionUri: string) {
  const clients = useSembleClients();
  const invalidate = useInvalidateSembleCollection(collectionUri);
  return useMutation({
    mutationKey: ["saveToSemble", clients?.viewerDid, collectionUri],
    mutationFn: async (input: { url: string; note?: string }) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      return clients.writer.saveUrl({ collectionUri, ...input });
    },
    onSuccess: invalidate,
  });
}

export function useRetrySembleLinkMutation(collectionUri: string) {
  const clients = useSembleClients();
  const invalidate = useInvalidateSembleCollection(collectionUri);
  return useMutation({
    mutationKey: ["retrySembleLink", clients?.viewerDid, collectionUri],
    mutationFn: async (card: SembleStrongRef) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      return clients.writer.linkCardToCollection(collectionUri, card);
    },
    onSuccess: invalidate,
  });
}

export function useRemoveSembleMembershipMutation(collectionUri: string) {
  const clients = useSembleClients();
  const invalidate = useInvalidateSembleCollection(collectionUri);
  return useMutation({
    mutationKey: ["removeSembleMembership", clients?.viewerDid, collectionUri],
    mutationFn: async (item: SembleSavedItem) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      if (!item.unlinkAvailable || !item.membership?.linkUri) {
        throw new Error("This collection membership is still syncing and cannot be removed yet.");
      }
      return clients.writer.removeMembership({
        collectionUri,
        linkUri: item.membership.linkUri,
        linkCid: item.membership.linkCid,
      });
    },
    onSuccess: invalidate,
  });
}

export function useUpdateSembleNoteMutation(collectionUri: string) {
  const clients = useSembleClients();
  const invalidate = useInvalidateSembleCollection(collectionUri);
  return useMutation({
    mutationKey: ["updateSembleNote", clients?.viewerDid, collectionUri],
    mutationFn: async (input: { noteUri: string; text: string }) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      await clients.writer.updateOwnedNote(input.noteUri, input.text);
    },
    onSuccess: invalidate,
  });
}

export function useCreateSembleNoteMutation(collectionUri: string) {
  const clients = useSembleClients();
  const invalidate = useInvalidateSembleCollection(collectionUri);
  return useMutation({
    mutationKey: ["createSembleNote", clients?.viewerDid, collectionUri],
    mutationFn: async (input: { card: SembleStrongRef; text: string }) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      return clients.writer.createNote(input.card, input.text);
    },
    onSuccess: invalidate,
  });
}

export function useSembleConnections(
  collectionUri: string,
  url: string | null | undefined,
) {
  const clients = useSembleClients();
  const targetUrl = url?.trim() ?? "";
  const query = useInfiniteQuery({
    queryKey: readLaterQueryKeys.connections(
      clients?.viewerDid ?? "signed-out",
      collectionUri,
      targetUrl,
    ),
    queryFn: ({ pageParam, signal }) => {
      if (!clients || !targetUrl) throw new Error("Choose a saved URL first.");
      return clients.reader.listConnections({
        url: targetUrl,
        cursor: pageParam,
        signal,
      });
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.cursor,
    enabled: Boolean(clients && targetUrl),
    staleTime: 60_000,
    gcTime: 7 * 24 * 60 * 60_000,
    refetchOnWindowFocus: false,
    retry: 1,
  });
  return {
    ...query,
    connections: query.data?.pages.flatMap((page) => page.connections) ?? [],
  };
}

function useInvalidateSembleConnections(collectionUri: string, url: string) {
  const { session } = useAuth();
  const queryClient = useQueryClient();
  return () => {
    if (!session) return;
    void queryClient.invalidateQueries({
      queryKey: readLaterQueryKeys.connections(session.did, collectionUri, url),
    });
  };
}

export function useCreateSembleConnectionMutation(
  collectionUri: string,
  sourceUrl: string,
) {
  const clients = useSembleClients();
  const invalidate = useInvalidateSembleConnections(collectionUri, sourceUrl);
  return useMutation({
    mutationKey: ["createSembleConnection", clients?.viewerDid, sourceUrl],
    mutationFn: async (input: {
      target: string;
      connectionType: string;
      note?: string;
    }) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      return clients.writer.createConnection({ source: sourceUrl, ...input });
    },
    onSuccess: invalidate,
  });
}

export function useUpdateSembleConnectionMutation(
  collectionUri: string,
  sourceUrl: string,
) {
  const clients = useSembleClients();
  const invalidate = useInvalidateSembleConnections(collectionUri, sourceUrl);
  return useMutation({
    mutationKey: ["updateSembleConnection", clients?.viewerDid, sourceUrl],
    mutationFn: async (input: {
      uri: string;
      target: string;
      connectionType: string;
      note?: string;
    }) => {
      if (!clients) throw new Error("Semble requires sign-in.");
      await clients.writer.updateOwnedConnection(input);
    },
    onSuccess: invalidate,
  });
}

export { SembleLinkCreationError };
