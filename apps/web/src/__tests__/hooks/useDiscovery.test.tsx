/**
 * Tests for useDiscovery and useRefreshDiscovery hooks.
 */

import type { OAuthSession } from "@atproto/oauth-client-browser";
import { describe, it, expect, afterEach, mock } from "bun:test";
import { renderHook, waitFor, act } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import { useDiscovery, useRefreshDiscovery } from "@/hooks/usePublications";
import { MOCK_PUBLICATIONS } from "../mocks/handlers/service";

const mockOAuthSession = {} as OAuthSession;

// ── Auth mock ─────────────────────────────────────────────────────────────────

mock.module("@/hooks/useAuth", () => ({
  useAuth: () => ({
    session: { did: "did:plc:testuser" },
    isLoading: false,
    applyOAuthSession: () => {},
    getOAuthSession: () => mockOAuthSession,
    getAuthFetch: () => null,
    signIn: async () => {},
    signOut: async () => {},
  }),
}));

let discoveryShouldFail = false;
let discoveryCallCount = 0;

mock.module("@/lib/atprotoClient", () => ({
  discoverPublications: async () => {
    discoveryCallCount++;
    if (discoveryShouldFail) {
      throw new Error("Discovery failed");
    }
    return MOCK_PUBLICATIONS;
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

afterEach(() => {
  discoveryShouldFail = false;
  discoveryCallCount = 0;
});

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useDiscovery", () => {
  it("returns discovered publications from public ATProto discovery", async () => {
    const { result } = renderHook(() => useDiscovery(), {
      wrapper: makeWrapper(),
    });

    await waitFor(() => expect(result.current.isLoading).toBe(false));

    expect(result.current.data).toHaveLength(MOCK_PUBLICATIONS.length);
    expect(result.current.data?.[0].title).toBe("Alice's Tech Blog");
    expect(result.current.data?.[0].authorDid).toBe("did:plc:alice");
  });

  it("errors when public ATProto discovery fails", async () => {
    discoveryShouldFail = true;

    const { result } = renderHook(() => useDiscovery(), {
      wrapper: makeWrapper(),
    });

    await waitFor(() => expect(result.current.isError).toBe(true));
  });
});

describe("useRefreshDiscovery", () => {
  it("re-fetches public ATProto discovery and populates query cache", async () => {
    const { result } = renderHook(() => useRefreshDiscovery(), {
      wrapper: makeWrapper(),
    });

    await act(async () => {
      await result.current.mutateAsync();
    });

    expect(discoveryCallCount).toBe(1);
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toHaveLength(MOCK_PUBLICATIONS.length);
  });

  it("errors when public ATProto discovery fails", async () => {
    discoveryShouldFail = true;

    const { result } = renderHook(() => useRefreshDiscovery(), {
      wrapper: makeWrapper(),
    });

    await act(async () => {
      try {
        await result.current.mutateAsync();
      } catch {
        // expected
      }
    });

    await waitFor(() => expect(result.current.isError).toBe(true));
  });
});
