import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";

import * as AuthHook from "@/hooks/useAuth";
import * as PDSHook from "@/hooks/usePDSClient";
import * as DummyReaderData from "@/lib/dummyReaderData";
import * as SyncPreferencesClient from "@/lib/syncPreferencesClient";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import { ACCOUNT_PREFERENCES_QUERY_KEY } from "@/hooks/useReadLaterPreferences";
import { loadCachedFeedDisplayPreferences } from "@/lib/feedPreferences";
import type { PDSClient, PreferencesRecord, RepoRecord } from "@/lib/pdsClient";

const did = "did:plc:feed-display-tests";
const session = { did };
const storageKey = `the-social-wire.feed-display.v1:${did}`;
const initial: RepoRecord<PreferencesRecord> = {
  uri: `at://${did}/app.thesocialwire.preferences/self`,
  cid: "previous-cid",
  value: {
    $type: "app.thesocialwire.preferences",
    createdAt: "2026-09-08T12:00:00Z",
    updatedAt: "2026-09-08T12:00:00Z",
    visibleFeeds: ["subscribed", "following"],
    showWire: true,
    showCircle: true,
    feedsWithUnreadCounts: ["subscribed"],
    rssArticleOpenMode: "reader",
  },
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

let queryClient: QueryClient;
const restoreSpies: Array<() => void> = [];
const upsertPreferences = mock<PDSClient["upsertPreferences"]>();
const fetchPreferences = mock<typeof SyncPreferencesClient.fetchSyncPreferences>();

function wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
}

function useSettingsAndSidebar() {
  return {
    settings: useFeedDisplayPreferences(),
    sidebar: useFeedDisplayPreferences(),
  };
}

describe("feed display preference persistence", () => {
  beforeEach(() => {
    queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
    });
    queryClient.setQueryData(ACCOUNT_PREFERENCES_QUERY_KEY, initial);
    window.localStorage.removeItem(storageKey);
    upsertPreferences.mockReset();
    fetchPreferences.mockReset();
    fetchPreferences.mockResolvedValue(initial);
    const auth = spyOn(AuthHook, "useAuth").mockReturnValue({
      session,
      getOAuthSession: () => ({}),
    } as ReturnType<typeof AuthHook.useAuth>);
    const pds = spyOn(PDSHook, "usePDSClient").mockReturnValue({
      upsertPreferences,
    } as unknown as PDSClient);
    const dummy = spyOn(DummyReaderData, "isDummyReaderDataEnabled").mockReturnValue(false);
    const sync = spyOn(SyncPreferencesClient, "fetchSyncPreferences").mockImplementation(fetchPreferences);
    restoreSpies.push(() => auth.mockRestore(), () => pds.mockRestore(),
      () => dummy.mockRestore(), () => sync.mockRestore());
  });

  afterEach(() => {
    cleanup();
    queryClient.clear();
    restoreSpies.splice(0).forEach((restore) => restore());
    window.localStorage.removeItem(storageKey);
  });

  for (const feed of ["wire", "circle"] as const) {
    const field = feed === "wire" ? "showWire" : "showCircle";
    const otherField = feed === "wire" ? "showCircle" : "showWire";

    it(`persists hiding ${feed} and shares the committed record with another observer`, async () => {
      const request = deferred<RepoRecord<PreferencesRecord>>();
      upsertPreferences.mockReturnValue(request.promise);
      const { result } = renderHook(useSettingsAndSidebar, { wrapper });

      act(() => result.current.settings.setDiscoveryFeedVisible(feed, false));
      await waitFor(() => {
        expect(upsertPreferences).toHaveBeenCalledTimes(1);
        expect(result.current.settings.isPending).toBe(true);
        expect(result.current.sidebar.preferences[field]).toBe(false);
      });
      expect(upsertPreferences.mock.calls[0]![0]).toMatchObject({
        [field]: false,
        [otherField]: true,
        visibleFeeds: initial.value.visibleFeeds,
        feedsWithUnreadCounts: initial.value.feedsWithUnreadCounts,
        rssArticleOpenMode: "reader",
      });
      expect(loadCachedFeedDisplayPreferences(window.localStorage, did)?.[field]).toBe(false);

      const saved = {
        ...initial,
        cid: "committed-cid",
        value: { ...initial.value, [field]: false },
      };
      await act(async () => request.resolve(saved));
      await waitFor(() => expect(result.current.settings.isPending).toBe(false));
      expect(result.current.settings.preferences[field]).toBe(false);
      expect(result.current.sidebar.preferences[field]).toBe(false);
      expect(queryClient.getQueryData<RepoRecord<PreferencesRecord>>(
        ACCOUNT_PREFERENCES_QUERY_KEY,
      )).toEqual(saved);
      expect(loadCachedFeedDisplayPreferences(window.localStorage, did)?.[field]).toBe(false);
    });

    it(`rolls back hiding ${feed} in both observers and local storage when saving fails`, async () => {
      const request = deferred<RepoRecord<PreferencesRecord>>();
      upsertPreferences.mockReturnValue(request.promise);
      // The rollback must work immediately, even while the subsequent refresh is unavailable.
      fetchPreferences.mockReturnValue(new Promise(() => {}));
      const { result } = renderHook(useSettingsAndSidebar, { wrapper });

      act(() => result.current.settings.setDiscoveryFeedVisible(feed, false));
      await waitFor(() => {
        expect(upsertPreferences).toHaveBeenCalledTimes(1);
        expect(result.current.sidebar.preferences[field]).toBe(false);
        expect(loadCachedFeedDisplayPreferences(window.localStorage, did)?.[field]).toBe(false);
      });

      const error = new Error("PDS write failed");
      await act(async () => request.reject(error));
      await waitFor(() => {
        expect(result.current.settings.error).toBe(error);
        expect(result.current.settings.preferences[field]).toBe(true);
        expect(result.current.sidebar.preferences[field]).toBe(true);
        expect(fetchPreferences).toHaveBeenCalledTimes(1);
      });
      expect(queryClient.getQueryData<RepoRecord<PreferencesRecord>>(
        ACCOUNT_PREFERENCES_QUERY_KEY,
      )).toEqual(initial);
      expect(loadCachedFeedDisplayPreferences(window.localStorage, did)?.[field]).toBe(true);
      expect(result.current.sidebar.preferences[otherField]).toBe(true);
    });
  }
});
