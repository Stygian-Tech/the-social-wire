/**
 * Tests for useEntries and useEntry hooks.
 *
 * atprotoClient is mocked directly — MSW would work too, but module-level
 * mocking is simpler here since the ATProto Agent isn't a plain fetch call
 * (it constructs requests internally).
 */

import { describe, it, expect, mock } from "bun:test";
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import { useEntries, useEntry } from "@/hooks/useEntries";
import {
  MOCK_ENTRIES,
  MOCK_ENTRY_DETAIL,
} from "../mocks/handlers/service";

// ── Module mocks ──────────────────────────────────────────────────────────────

mock.module("@/hooks/useAuth", () => ({
  useAuth: () => ({
    session: { did: "did:plc:testuser" },
    isLoading: false,
    applyOAuthSession: () => {},
    getOAuthSession: () => null,
    getAuthFetch: () => null,
    signIn: async () => {},
    signOut: async () => {},
  }),
}));

mock.module("@/lib/atprotoClient", () => ({
  listEntries: async (authorDid: string) => {
    if (authorDid === "did:plc:alice") {
      return { entries: MOCK_ENTRIES, cursor: undefined };
    }
    return { entries: [], cursor: undefined };
  },
  getEntry: async (entryId: string) => {
    if (entryId === MOCK_ENTRY_DETAIL.entryId) {
      return MOCK_ENTRY_DETAIL;
    }
    return null;
  },
}));

// ── Test wrapper ──────────────────────────────────────────────────────────────

function makeWrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useEntries", () => {
  it("fetches entries for a publication by author DID", async () => {
    const { result } = renderHook(() => useEntries("did:plc:alice"), {
      wrapper: makeWrapper(),
    });

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    const entries = result.current.data?.pages.flatMap((p) => p.entries) ?? [];
    expect(entries).toHaveLength(MOCK_ENTRIES.length);
    expect(entries[0].title).toBe("First Post");
    expect(entries[0].entryId).toBe(
      "at://did:plc:alice/site.standard.document/entry1"
    );
  });

  it("returns empty pages when authorDid is null", async () => {
    const { result } = renderHook(() => useEntries(null), {
      wrapper: makeWrapper(),
    });

    // Query is disabled when authorDid is null
    expect(result.current.isLoading).toBe(false);
    expect(result.current.data).toBeUndefined();
  });

  it("returns empty entries for unknown author", async () => {
    const { result } = renderHook(() => useEntries("did:plc:unknown"), {
      wrapper: makeWrapper(),
    });

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    const entries = result.current.data?.pages.flatMap((p) => p.entries) ?? [];
    expect(entries).toHaveLength(0);
  });
});

describe("useEntry", () => {
  it("fetches entry detail by AT-URI", async () => {
    const { result } = renderHook(
      () => useEntry("at://did:plc:alice/site.standard.document/entry1"),
      { wrapper: makeWrapper() }
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    expect(result.current.data?.title).toBe(MOCK_ENTRY_DETAIL.title);
    expect(result.current.data?.contentHtml).toBe(MOCK_ENTRY_DETAIL.contentHtml);
    expect(result.current.data?.originalUrl).toBe(MOCK_ENTRY_DETAIL.originalUrl);
  });

  it("returns null data when entryId is null", async () => {
    const { result } = renderHook(() => useEntry(null), {
      wrapper: makeWrapper(),
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.data).toBeUndefined();
  });

  it("returns null for unknown entry", async () => {
    const { result } = renderHook(
      () => useEntry("at://did:plc:alice/site.standard.document/nonexistent"),
      { wrapper: makeWrapper() }
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));
    expect(result.current.data).toBeNull();
  });
});
