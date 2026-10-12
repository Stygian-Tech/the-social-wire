import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Wire from "@/lib/wireFeedClient";
import * as Edition from "@/lib/wireEditionClient";
import { dummyWireEdition } from "@/lib/dummyWireEditionData";
import { WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";
import { useWireEdition } from "@/hooks/useWireEdition";
import { useWireFeedEntries } from "@/hooks/useWireFeed";

const restores: (() => void)[] = [];
let client: QueryClient;
const oauth = { did: "did:plc:proof-viewer", getTokenInfo: async () => ({ scope: WIRE_MODERATION_RPC_SCOPES.join(" ") }) } as unknown as OAuthSession;
function wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, isLoading: false, getOAuthSession: () => oauth, oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
  const catalog = spyOn(Wire, "getWireFeedCatalog").mockResolvedValue({ enabled: true, available: true, supportedLanguages: ["en"], title: "The Wire", subtitle: "News" });
  restores.push(() => auth.mockRestore(), () => catalog.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });

it("passes OAuth to warm edition and continuation reads without preparing a PDS proof pool", async () => {
  const fixture = { ...dummyWireEdition(), moreCursor: "next" };
  const edition = spyOn(Edition, "getWireEdition").mockResolvedValue(fixture);
  const more = spyOn(Wire, "getWire").mockResolvedValue({ generationId: fixture.generationId, generatedAt: fixture.generatedAt, language: "en", source: "ranked", degraded: false, items: fixture.stories });
  const pool = spyOn(Wire, "createWireModerationDpopProofPool").mockImplementation(async () => { throw new Error("Warm hooks must not probe the PDS"); });
  restores.push(() => edition.mockRestore(), () => more.mockRestore(), () => pool.mockRestore());
  const { result } = renderHook(() => useWireEdition({ enabled: true }), { wrapper });
  await waitFor(() => expect(result.current.data?.pages).toHaveLength(1));
  expect(edition.mock.calls[0]?.[0]?.oauthSession).toBe(oauth);
  expect(edition.mock.calls[0]?.[0]?.moderationDpopProofPool).toBeUndefined();
  await act(async () => { await result.current.fetchNextPage(); });
  expect(more.mock.calls[0]?.[0]?.oauthSession).toBe(oauth);
  expect(more.mock.calls[0]?.[0]?.moderationDpopProofPool).toBeUndefined();
  expect(pool).not.toHaveBeenCalled();
});

it("passes OAuth to warm ranked feeds and pagination without preparing a PDS proof pool", async () => {
  const fixture = dummyWireEdition();
  const feed = spyOn(Wire, "getWire").mockImplementation(async args => ({ generationId: fixture.generationId, generatedAt: fixture.generatedAt, language: "en", source: "ranked", degraded: false, items: fixture.stories, cursor: args?.cursor ? undefined : "next" }));
  const pool = spyOn(Wire, "createWireModerationDpopProofPool").mockImplementation(async () => { throw new Error("Warm hooks must not probe the PDS"); });
  restores.push(() => feed.mockRestore(), () => pool.mockRestore());
  const { result } = renderHook(() => useWireFeedEntries({ enabled: true }), { wrapper });
  await waitFor(() => expect(result.current.data?.pages).toHaveLength(1));
  await act(async () => { await result.current.fetchNextPage(); });
  expect(feed).toHaveBeenCalledTimes(2);
  for (const [args] of feed.mock.calls) {
    expect(args?.oauthSession).toBe(oauth);
    expect(args?.moderationDpopProofPool).toBeUndefined();
  }
  expect(pool).not.toHaveBeenCalled();
});
