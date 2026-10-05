"use client";
import { useCallback, useEffect, useRef } from "react";
import {
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { usePDSClient } from "@/hooks/usePDSClient";
import { useSidebarBootstrap } from "@/contexts/PublicationSidebarContext";
import {
  parseStandardReaderListUri,
  standardReaderListRecord,
  type CreateStandardReaderListInput,
} from "@/lib/standardReaderList";
import {
  getStandardReaderLists,
  mergeStandardReaderListsPage,
  refreshStandardReaderLists,
  resolveStandardReaderList,
  searchStandardReaderLists,
  standardReaderListsQueryKey,
  type StandardReaderList,
  type StandardReaderListsPage,
} from "@/lib/standardReaderListsClient";

function listWriteError(error: unknown): never {
  if ((error as { originalDeleted?: boolean } | null)?.originalDeleted) throw error;
  const failure = error as { status?: number; message?: string };
  if (failure?.status === 401 || failure?.status === 403 ||
    /scope|permission|unauthor/i.test(failure?.message ?? "")) {
    throw new Error("Sign out and sign in again to allow updating Lists on your PDS.");
  }
  throw error;
}

export function useStandardReaderLists() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const pds = usePDSClient();
  const bootstrap = useSidebarBootstrap();
  const client = useQueryClient();
  const oauth = getOAuthSession();
  const viewer = session?.did ?? "public";
  const key = standardReaderListsQueryKey(viewer, oauthSessionReloadSeq);
  const deletedKey = ["standardReaderDeletedLists", viewer, oauthSessionReloadSeq] as const;
  const withoutDeletedLists = (page: StandardReaderListsPage): StandardReaderListsPage => {
    const deleted = new Set(client.getQueryData<string[]>(deletedKey) ?? []);
    return { ...page, lists: page.lists.filter(list => !deleted.has(list.uri)) };
  };
  const rememberDeletedList = (uri: string) => {
    // Inactive deletion markers must outlive the normal five-minute cache GC during this auth session.
    client.setQueryDefaults(deletedKey, { gcTime: Infinity });
    client.setQueryData<string[]>(deletedKey, previous => [...new Set([...(previous ?? []), uri])]);
    client.setQueryData<StandardReaderListsPage>(key, previous => previous ? withoutDeletedLists(previous) : previous);
  };
  const context = `${viewer}:${oauthSessionReloadSeq}`;
  const current = useRef(context);
  useEffect(() => {
    current.current = context;
  }, [context]);
  const query = useQuery({
    queryKey: key,
    queryFn: async ({ signal }) =>
      withoutDeletedLists(mergeStandardReaderListsPage(
        client.getQueryData(key),
        await getStandardReaderLists(oauth!, signal),
      )),
    enabled: !!oauth && !!session && bootstrap.bootstrapStreamComplete,
    staleTime: (query) =>
      (
        query.state.data as
          (StandardReaderListsPage & { complete?: boolean }) | undefined
      )?.complete === false
        ? 0
        : 60000,
  });
  const refreshMutation = useMutation({
    mutationFn: async (captured: string) => {
      if (!oauth) throw new Error("Sign in to refresh Lists.");
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Try again.");
      const page = await refreshStandardReaderLists(oauth);
      if (current.current === captured && getOAuthSession() === oauth) {
        client.setQueryData(
          key,
          withoutDeletedLists(mergeStandardReaderListsPage(client.getQueryData(key), page)),
        );
        const feedKey = ["aggregateEntries", viewer, "list"];
        await client.cancelQueries({ queryKey: feedKey });
        client.setQueriesData<InfiniteData<unknown>>(
          { queryKey: feedKey },
          (previous) =>
            previous
              ? {
                  ...previous,
                  pages: previous.pages.slice(0, 1),
                  pageParams: [undefined],
                }
              : previous,
        );
        await client.invalidateQueries({ queryKey: feedKey });
      }
    },
  });
  const saveMutation = useMutation({
    mutationFn: async ({
      uri,
      remove,
      context: captured,
    }: {
      uri: string;
      remove: boolean;
      context: string;
    }) => {
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Try again.");
      if (!pds) throw new Error("Sign in to save Lists.");
      try {
        if (remove) await pds.removeStandardReaderList(uri);
        else await pds.saveStandardReaderList(uri);
      } catch (error) {
        listWriteError(error);
      }
    },
    onMutate: async ({ uri, remove, context: captured }) => {
      await client.cancelQueries({ queryKey: key, exact: true });
      const previous = client.getQueryData<StandardReaderListsPage>(key);
      const known =
        previous?.lists.find((list) => list.uri === uri) ??
        client.getQueryData<StandardReaderList>([
          "standardReaderList",
          viewer,
          oauthSessionReloadSeq,
          uri,
        ]);
      if (current.current === captured && known)
        client.setQueryData<StandardReaderListsPage>(key, {
          refreshedAt: previous?.refreshedAt ?? "",
          lists: remove
            ? (previous?.lists ?? []).flatMap((list) =>
                list.uri !== uri
                  ? [list]
                  : list.owned
                    ? [{ ...list, saved: false }]
                    : [],
              )
            : [
                ...(previous?.lists ?? []).filter((list) => list.uri !== uri),
                { ...known, saved: true },
              ],
        });
      return { previous, captured };
    },
    onError: (_error, _variables, state) => {
      if (state && current.current === state.captured)
        client.setQueryData(key, state.previous);
    },
    onSuccess: async (_data, _variables, state) => {
      if (
        state &&
        current.current === state.captured &&
        getOAuthSession() === oauth
      )
        await refreshMutation
          .mutateAsync(state.captured)
          .catch(() => undefined);
    },
  });
  const createMutation = useMutation({
    mutationFn: async ({ input, context: captured }: {
      input: CreateStandardReaderListInput;
      context: string;
    }): Promise<StandardReaderList> => {
      if (!pds || !oauth) throw new Error("Sign in to create Lists.");
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Try again.");
      const record = standardReaderListRecord(input);
      let created: { uri: string; cid: string };
      try {
        created = await pds.createStandardReaderList(input);
      } catch (error) {
        listWriteError(error);
      }
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Refresh Lists on the original account to find your created list.");
      const list: StandardReaderList = {
        uri: created.uri,
        name: record.name,
        ...(record.description ? { description: record.description } : {}),
        creatorDid: viewer,
        publications: record.publications,
        users: record.users ?? [],
        owned: true,
        saved: false,
      };
      client.setQueryData(["standardReaderList", viewer, oauthSessionReloadSeq, list.uri], list);
      client.setQueryData<StandardReaderListsPage>(key, previous => ({
        ...previous,
        refreshedAt: previous?.refreshedAt ?? "",
        lists: [...(previous?.lists ?? []).filter(value => value.uri !== list.uri), list],
      }));
      await refreshMutation.mutateAsync(captured).catch(() => undefined);
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Refresh Lists on the original account to find your created list.");
      return list;
    },
  });
  const deleteMutation = useMutation({
    mutationFn: async ({ uri, context: captured }: { uri: string; context: string }) => {
      if (!pds || !oauth) throw new Error("Sign in to delete Lists.");
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Try again.");
      try {
        await pds.deleteOwnedStandardReaderList(uri);
      } catch (error) {
        listWriteError(error);
      }
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Refresh Lists on the original account.");
    },
    onMutate: async ({ uri, context: captured }) => {
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Try again.");
      if (!parseStandardReaderListUri(uri)?.startsWith(`at://${viewer}/app.standard-reader.list/`))
        throw new Error("Only a list created by your signed-in account can be deleted.");
      await client.cancelQueries({ queryKey: key, exact: true });
      const previous = client.getQueryData<StandardReaderListsPage>(key);
      if (current.current === captured && getOAuthSession() === oauth && previous)
        client.setQueryData(key, { ...previous, lists: previous.lists.filter(list => list.uri !== uri) });
      return { previous, captured };
    },
    onError: async (error, { uri }, state) => {
      if (!state || current.current !== state.captured || getOAuthSession() !== oauth) return;
      if ((error as { originalDeleted?: boolean }).originalDeleted) {
        rememberDeletedList(uri);
        client.removeQueries({ queryKey: ["standardReaderList", viewer, oauthSessionReloadSeq, uri], exact: true });
        client.removeQueries({ queryKey: ["aggregateEntries", viewer, "list", uri] });
        await refreshMutation.mutateAsync(state.captured).catch(() => undefined);
      } else {
        client.setQueryData(key, state.previous);
      }
    },
    onSuccess: async (_data, { uri }, state) => {
      if (!state || current.current !== state.captured || getOAuthSession() !== oauth) return;
      rememberDeletedList(uri);
      client.removeQueries({ queryKey: ["standardReaderList", viewer, oauthSessionReloadSeq, uri], exact: true });
      client.removeQueries({ queryKey: ["aggregateEntries", viewer, "list", uri] });
      await refreshMutation.mutateAsync(state.captured).catch(() => undefined);
    },
  });
  const resolveList = useCallback(
    async (input: string) => {
      if (!oauth) throw new Error("Sign in to open Lists.");
      const captured = context;
      const list = await resolveStandardReaderList(oauth, input);
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Try again.");
      client.setQueryData(
        ["standardReaderList", viewer, oauthSessionReloadSeq, list.uri],
        list,
      );
      return list;
    },
    [oauth, context, getOAuthSession, client, viewer, oauthSessionReloadSeq],
  );
  const searchCreator = useCallback(
    async (creator: string) => {
      if (!oauth) throw new Error("Sign in to find Lists.");
      const captured = context;
      const page = await searchStandardReaderLists(oauth, creator);
      if (current.current !== captured || getOAuthSession() !== oauth)
        throw new Error("Your account changed. Try again.");
      for (const list of page.lists)
        client.setQueryData(
          ["standardReaderList", viewer, oauthSessionReloadSeq, list.uri],
          list,
        );
      return page.lists;
    },
    [oauth, context, getOAuthSession, client, viewer, oauthSessionReloadSeq],
  );
  const resolveCreator = useCallback(async (input: string): Promise<{ did: string; handle?: string }> => {
    if (!oauth) throw new Error("Sign in to find authors.");
    const captured = context;
    const page = await searchStandardReaderLists(oauth, input);
    if (current.current !== captured || getOAuthSession() !== oauth)
      throw new Error("Your account changed. Try again.");
    if (!page.creatorDid || !/^did:[a-z]+:[A-Za-z0-9._:%-]+$/.test(page.creatorDid))
      throw new Error("The creator could not be resolved. Try again.");
    return { did: page.creatorDid, ...(input.startsWith("did:") ? {} : { handle: input.trim().replace(/^@/, "") }) };
  }, [oauth, context, getOAuthSession]);
  return {
    lists: query.data?.lists ?? [],
    query,
    refresh: () => refreshMutation.mutateAsync(context),
    refreshing:
      refreshMutation.variables === context && refreshMutation.isPending,
    error:
      (createMutation.variables?.context === context ? createMutation.error : null) ??
      (deleteMutation.variables?.context === context ? deleteMutation.error : null) ??
      (saveMutation.variables?.context === context
        ? saveMutation.error
        : null) ??
      (refreshMutation.variables === context ? refreshMutation.error : null) ??
      query.error ??
      (query.data?.complete === false
        ? new Error(
            "Some lists could not be refreshed. Showing previously loaded lists. Try Refresh.",
          )
        : null),
    signedIn: !!session,
    saveList: (uri: string) =>
      saveMutation.mutateAsync({ uri, remove: false, context }),
    removeList: (uri: string) =>
      saveMutation.mutateAsync({ uri, remove: true, context }),
    createList: (input: CreateStandardReaderListInput) => createMutation.mutateAsync({ input, context }),
    deleteList: (uri: string) => deleteMutation.mutateAsync({ uri, context }),
    creating: createMutation.variables?.context === context && createMutation.isPending,
    deleting: deleteMutation.variables?.context === context && deleteMutation.isPending,
    saving:
      (saveMutation.variables?.context === context && saveMutation.isPending) ||
      (createMutation.variables?.context === context && createMutation.isPending) ||
      (deleteMutation.variables?.context === context && deleteMutation.isPending),
    searchCreator,
    resolveCreator,
    resolveList,
  };
}
export function useStandardReaderList(uri: string | null) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const oauth = getOAuthSession();
  return useQuery({
    queryKey: [
      "standardReaderList",
      session?.did ?? "public",
      oauthSessionReloadSeq,
      uri,
    ],
    queryFn: ({ signal }) => resolveStandardReaderList(oauth!, uri!, signal),
    enabled: !!uri && !!session && !!oauth,
    staleTime: 60000,
  });
}
