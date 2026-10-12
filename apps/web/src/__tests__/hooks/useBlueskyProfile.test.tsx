import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import { useBlueskyProfile } from "@/hooks/useBlueskyProfile";

const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:web:labeler.test", labels: {} }], mutedWords: [], hiddenPosts: [] } };
let cache: QueryClient;
let oauthDid: string;
let calls: { actor: string; headers: Headers; signal?: AbortSignal | null }[];
let restore: () => void;
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={cache}>{children}</QueryClientProvider>; }
beforeEach(() => {
  cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  oauthDid = did; calls = [];
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did }, oauthSessionReloadSeq: 0, getOAuthSession: () => ({ did: oauthDid, fetchHandler: async (path: string, init?: RequestInit) => {
    const url = new URL(path, "https://pds.test");
    const actor = url.searchParams.get("actor")!;
    calls.push({ actor, headers: new Headers(init?.headers), signal: init?.signal });
    return Response.json({ did: actor, handle: "other.test", displayName: actor });
  } } as unknown as OAuthSession) } as ReturnType<typeof Auth.useAuth>));
  restore = () => auth.mockRestore();
});
afterEach(() => { cleanup(); cache.clear(); restore(); });
describe("viewer-aware profile lookup", () => {
  it("uses the authenticated AppView proxy with labelers and isolates viewed actors", async () => {
    const { result, rerender } = renderHook(({ actor }) => useBlueskyProfile(actor, moderation), { initialProps: { actor: "did:plc:other" }, wrapper: Wrapper });
    await waitFor(() => expect(result.current.data?.did).toBe("did:plc:other"));
    expect(calls[0]!.headers.get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
    expect(calls[0]!.headers.get("atproto-accept-labelers")).toContain("did:web:labeler.test");
    expect(calls[0]!.signal).toBeInstanceOf(AbortSignal);
    rerender({ actor: "did:plc:third" });
    expect(result.current.data).toBeUndefined();
    await waitFor(() => expect(result.current.data?.did).toBe("did:plc:third"));
    expect(calls.map(call => call.actor)).toEqual(["did:plc:other", "did:plc:third"]);
  });
  it("waits for viewer moderation and refuses mismatched OAuth identity before transport", async () => {
    const { result, rerender } = renderHook(({ safety }) => useBlueskyProfile("did:plc:other", safety), { initialProps: { safety: undefined as ModerationOpts | undefined }, wrapper: Wrapper });
    expect(calls).toHaveLength(0);
    oauthDid = "did:plc:changed";
    rerender({ safety: moderation });
    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(calls).toHaveLength(0);
  });
});
