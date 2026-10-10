import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Dummy from "@/lib/dummyReaderData";
import { BSKY_APPVIEW_PUBLIC } from "@/lib/atprotoClient";
import * as Atproto from "@/lib/atprotoClient";
import { useViewerProfile } from "@/hooks/useViewerProfile";

const alice = "did:plc:alice";
const bob = "did:plc:bob";
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
let viewer: string | undefined;
let queryClient: QueryClient;
const restores: (() => void)[] = [];
const oauthFetch = mock(async (path: string) => {
  expect(String(path)).toContain("com.atproto.repo.getRecord");
  return Response.json({ uri: `at://${alice}/app.bsky.actor.profile/self`, cid, value: { $type: "app.bsky.actor.profile", displayName: "PDS Alice", description: "Repository fallback" } });
});
function Wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
}
beforeEach(() => {
  viewer = alice;
  oauthFetch.mockClear();
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: viewer ? { did: viewer } : null, getOAuthSession: () => ({ did: viewer, fetchHandler: oauthFetch } as unknown as OAuthSession) } as ReturnType<typeof Auth.useAuth>));
  const dummy = spyOn(Dummy, "isDummyReaderDataEnabled").mockReturnValue(false);
  // Other hook suites replace this module factory. Restore the real transport for these boundary tests.
  const agent = spyOn(Atproto, "createOAuthAgent").mockImplementation(session => new Agent(session));
  restores.push(() => auth.mockRestore(), () => dummy.mockRestore(), () => agent.mockRestore());
});
afterEach(() => { cleanup(); queryClient.clear(); restores.splice(0).forEach(restore => restore()); });

describe("viewer profile public read boundary", () => {
  it("reads actual banner and zero or nonzero statistics without sending OAuth to AppView", async () => {
    const fetch = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      expect(url.origin).toBe(BSKY_APPVIEW_PUBLIC);
      expect(url.searchParams.get("actor")).toBe(alice);
      expect(new Headers(init?.headers).has("Authorization")).toBe(false);
      return Response.json({ did: alice, handle: "alice.test", displayName: "Alice", banner: "https://images.test/banner.png", followersCount: 0, followsCount: 12, postsCount: 34 });
    }, { preconnect: globalThis.fetch.preconnect }));
    restores.push(() => fetch.mockRestore());
    const { result } = renderHook(() => useViewerProfile(), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toMatchObject({ did: alice, banner: "https://images.test/banner.png", followersCount: 0, followsCount: 12, postsCount: 34 });
    expect(oauthFetch).not.toHaveBeenCalled();
  });

  it("falls back to viewer PDS text without inventing indexed counts or banner URLs", async () => {
    const fetch = spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ error: "ProfileNotFound" }, { status: 400 }));
    restores.push(() => fetch.mockRestore());
    const { result } = renderHook(() => useViewerProfile(), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toEqual({ did: alice, handle: alice, displayName: "PDS Alice", description: "Repository fallback" });
    expect(oauthFetch).toHaveBeenCalledTimes(1);
    expect(String(oauthFetch.mock.calls[0]?.[0])).toContain("com.atproto.repo.getRecord");
    expect(result.current.data?.followersCount).toBeUndefined();
    expect(result.current.data?.banner).toBeUndefined();
  });

  it("never presents the previous viewer profile while a different viewer loads", async () => {
    const fetch = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      if (url.searchParams.get("actor") === bob) return new Promise<Response>(() => {});
      return Response.json({ did: alice, handle: "alice.test", followersCount: 10 });
    }, { preconnect: globalThis.fetch.preconnect }));
    restores.push(() => fetch.mockRestore());
    const { result, rerender } = renderHook(() => useViewerProfile(), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.data?.did).toBe(alice));
    viewer = bob;
    rerender();
    expect(result.current.data).toBeUndefined();
  });
});
