/**
 * Tests for useEntries and useEntry hooks (Thin AppView gateway path).
 */

import { describe, it, expect, mock, beforeEach, afterEach } from "bun:test";
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import { useEntries, useEntry } from "@/hooks/useEntries";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/hooks/usePublicationSidebarData";
import {
  MOCK_ENTRIES,
  MOCK_ENTRY_DETAIL,
} from "../mocks/handlers/service";

const ORIG_ENV = { ...process.env };

const mockFetchHandler = mock(async (url: string) => {
  if (url.includes("/v1/appview/entries")) {
    return new Response(
      JSON.stringify({ entries: MOCK_ENTRIES, cursor: undefined }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  if (url.includes("/v1/appview/entry")) {
    return new Response(
      JSON.stringify(MOCK_ENTRY_DETAIL),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  return new Response("not found", { status: 404 });
});

mock.module("@/hooks/useAuth", () => ({
  useAuth: () => ({
    session: { did: "did:plc:testuser" },
    isLoading: false,
    oauthSessionReloadSeq: 0,
    applyOAuthSession: () => {},
    getOAuthSession: () => ({ fetchHandler: mockFetchHandler }),
    getAuthFetch: () => null,
    reconcileOAuthSession: async () => false,
    signIn: async () => {},
    signOut: async () => {},
  }),
}));

function makeWrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  qc.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY("did:plc:testuser"), {
    viewerDid: "did:plc:testuser",
    folders: [],
    publicationPrefs: [],
    allPublicationRows: [
      {
        publicationId: "did:plc:alice",
        authorDid: "did:plc:alice",
        authorHandle: "alice",
        title: "Alice",
        discoveredAt: "2026-01-01T00:00:00.000Z",
        appViewScope: {
          authorDid: "did:plc:alice",
          publicationAtUri: null,
          publicationScopeAtUris: [],
          publicationSiteUrls: [],
        },
      },
    ],
    myPublications: [],
    subscribedUnfoldered: [],
    followingTabPublications: [],
    enrollAuthorDids: [],
    refreshedAt: "2026-01-01T00:00:00.000Z",
  });

  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  };
}

describe("useEntries", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "true";
    mockFetchHandler.mockClear();
  });

  afterEach(() => {
    process.env = { ...ORIG_ENV };
  });

  it("fetches entries from AppView for a publication", async () => {
    const { result } = renderHook(() => useEntries("did:plc:alice"), {
      wrapper: makeWrapper(),
    });

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    const entries = result.current.data?.pages.flatMap((p) => p.entries) ?? [];
    expect(entries).toHaveLength(MOCK_ENTRIES.length);
    expect(entries[0].title).toBe("First Post");
    expect(mockFetchHandler).toHaveBeenCalled();
  });

  it("returns empty pages when publicationKey is null", async () => {
    const { result } = renderHook(() => useEntries(null), {
      wrapper: makeWrapper(),
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.data).toBeUndefined();
  });
});

describe("useEntry", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "true";
    mockFetchHandler.mockClear();
  });

  afterEach(() => {
    process.env = { ...ORIG_ENV };
  });

  it("fetches entry detail from AppView by AT-URI", async () => {
    const { result } = renderHook(
      () => useEntry("at://did:plc:alice/site.standard.document/entry1"),
      { wrapper: makeWrapper() }
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    expect(result.current.data?.title).toBe(MOCK_ENTRY_DETAIL.title);
    expect(result.current.data?.contentHtml).toBe(MOCK_ENTRY_DETAIL.contentHtml);
    expect(mockFetchHandler).toHaveBeenCalled();
  });

  it("returns null data when entryId is null", async () => {
    const { result } = renderHook(() => useEntry(null), {
      wrapper: makeWrapper(),
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.data).toBeUndefined();
  });
});
