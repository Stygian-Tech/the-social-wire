import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as API from "@/lib/socialModerationClient";
import { useSocialModerationSettings } from "@/hooks/useSocialModerationSettings";
let viewer: string;
let oauth: string;
let client: QueryClient;
const restores: (() => void)[] = [];
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  viewer = "did:plc:alice"; oauth = viewer;
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession: () => ({ did: oauth }) as OAuthSession, oauthSessionReloadSeq: 0 } as ReturnType<typeof Auth.useAuth>));
  const settings = spyOn(API, "getSocialModerationSettings").mockResolvedValue({ labelers: [], moderation: { userDid: viewer, prefs: { labelers: [] } } } as unknown as Awaited<ReturnType<typeof API.getSocialModerationSettings>>);
  restores.push(() => auth.mockRestore(), () => settings.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });

it("rejects stale OAuth identity before labeler writes", async () => {
  const write = spyOn(API, "changeSocialLabeler").mockResolvedValue(); restores.push(() => write.mockRestore());
  oauth = "did:plc:bob";
  const { result } = renderHook(() => useSocialModerationSettings(), { wrapper: Wrapper });
  await act(async () => { await expect(result.current.change.mutateAsync({ type: "subscribe", did: "did:plc:labeler" })).rejects.toThrow("account changed"); });
  await waitFor(() => expect(result.current.settings.isError).toBe(true));
  expect(write).not.toHaveBeenCalled();
});

it("resets previous catalog and timeline safety for only the affected viewer after writes", async () => {
  const write = spyOn(API, "changeSocialLabeler").mockResolvedValue(); restores.push(() => write.mockRestore());
  const oldCatalog = ["blueskySocial", viewer, "catalog"];
  const oldTimeline = ["blueskySocial", viewer, "timeline"];
  const otherCatalog = ["blueskySocial", "did:plc:bob", "catalog"];
  client.setQueryData(oldCatalog, { labels: "stale" });
  client.setQueryData(oldTimeline, { posts: "old" });
  client.setQueryData(otherCatalog, { labels: "other" });
  const { result } = renderHook(() => useSocialModerationSettings(), { wrapper: Wrapper });
  await waitFor(() => expect(result.current.settings.isSuccess).toBe(true));
  await act(async () => { await result.current.change.mutateAsync({ type: "subscribe", did: "did:plc:labeler" }); });
  await waitFor(() => expect(result.current.settings.isSuccess).toBe(true));
  expect(client.getQueryData(oldCatalog)).toBeUndefined();
  expect(client.getQueryData(oldTimeline)).toBeUndefined();
  expect(client.getQueryData<{ labels: string }>(otherCatalog)).toEqual({ labels: "other" });
});

it("uses a new query for account changes without displaying previous labeler settings", async () => {
  const { result, rerender } = renderHook(() => useSocialModerationSettings(), { wrapper: Wrapper });
  await waitFor(() => expect(result.current.settings.isSuccess).toBe(true));
  const next = spyOn(API, "getSocialModerationSettings").mockImplementation(() => new Promise(() => {})); restores.push(() => next.mockRestore());
  viewer = "did:plc:bob"; oauth = viewer;
  rerender();
  expect(result.current.settings.data).toBeUndefined();
});
