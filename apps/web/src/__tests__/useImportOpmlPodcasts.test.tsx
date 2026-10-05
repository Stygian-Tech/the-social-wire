import { afterEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import * as auth from "@/hooks/useAuth";
import * as client from "@/lib/podcasts/client";
import { useImportOpmlPodcasts } from "@/hooks/useImportOpmlPodcasts";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
const feed = { feedUrl: "https://example.org/feed?token=secret", title: "Members Audio", categoryPath: [], sourceIndex: 0 };
function setup() {
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  restores.push(() => cache.clear());
  const oauth = { did: "did:alice" } as unknown as OAuthSession;
  const authSpy = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof auth.useAuth>);
  restores.push(() => authSpy.mockRestore());
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={cache}>{children}</QueryClientProvider>;
  return { cache, oauth, authSpy, wrapper };
}

it("uses private resolution exclusively and never creates a public PDS record", async () => {
  const fixture = setup();
  const write = spyOn(client, "writePodcastSubscription").mockResolvedValue();
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string): Promise<T> => path === "shows" ? { shows: [] } as T : { show: { id: "private", title: "Members Audio", sourceKind: "private-rss", visibility: "private" } } as T);
  restores.push(() => write.mockRestore(), () => request.mockRestore());
  const { result } = renderHook(() => useImportOpmlPodcasts(false), { wrapper: fixture.wrapper });
  await act(async () => { await result.current.importer.mutateAsync({ feeds: [feed], privateFeeds: true, onProgress() {} }); });
  expect(request).toHaveBeenCalledWith(fixture.oauth, "private/resolve", "POST", { url: feed.feedUrl });
  expect(write).not.toHaveBeenCalled();
  await waitFor(() => expect(result.current.importer.data?.imported).toHaveLength(1));
});

it("stops an account-switched import after resolution and before subscription writes", async () => {
  const fixture = setup();
  let resolved: (value: unknown) => void = () => {};
  const write = spyOn(client, "writePodcastSubscription").mockResolvedValue();
  const request = spyOn(client, "podcastRequest").mockImplementation(<T,>(_oauth: OAuthSession, path: string): Promise<T> => path === "shows" ? Promise.resolve({ shows: [] } as T) : new Promise<T>(resolve => { resolved = value => resolve(value as T); }));
  restores.push(() => write.mockRestore(), () => request.mockRestore());
  const { result, rerender } = renderHook(() => useImportOpmlPodcasts(false), { wrapper: fixture.wrapper });
  let pending: Promise<unknown> = Promise.resolve();
  await act(async () => { pending = result.current.importer.mutateAsync({ feeds: [{ ...feed, feedUrl: "https://example.org/feed" }], privateFeeds: false, onProgress() {} }).catch(error => error); });
  fixture.authSpy.mockReturnValue({ session: { did: "did:bob" }, getOAuthSession: () => fixture.oauth } as ReturnType<typeof auth.useAuth>);
  rerender();
  await act(async () => resolved({ show: { id: "public", title: "Public Show", sourceKind: "rss" } }));
  expect((await pending as Error).message).toContain("Account Changed");
  expect(write).not.toHaveBeenCalled();
});

it("rejects a stale OAuth session before sending any import requests", async () => {
  const fixture = setup();
  fixture.authSpy.mockReturnValue({ session: { did: "did:bob" }, getOAuthSession: () => fixture.oauth } as ReturnType<typeof auth.useAuth>);
  const request = spyOn(client, "podcastRequest");
  restores.push(() => request.mockRestore());
  const { result } = renderHook(() => useImportOpmlPodcasts(false), { wrapper: fixture.wrapper });
  await expect(result.current.importer.mutateAsync({ feeds: [feed], privateFeeds: true, onProgress() {} })).rejects.toThrow("Account Changed");
  expect(request).not.toHaveBeenCalled();
});
