import { afterEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import * as auth from "@/hooks/useAuth";
import * as client from "@/lib/podcasts/client";
import { PODCAST_SUBSCRIPTIONS_CHANGED_EVENT } from "@/lib/podcasts/subscriptionsChanged";
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
  const events: unknown[] = [];
  const listen = (event: Event) => events.push((event as CustomEvent).detail);
  window.addEventListener(PODCAST_SUBSCRIPTIONS_CHANGED_EVENT, listen);
  restores.push(() => window.removeEventListener(PODCAST_SUBSCRIPTIONS_CHANGED_EVENT, listen));
  return { cache, oauth, authSpy, wrapper, events };
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
  expect(fixture.events).toEqual([{ viewerDid: fixture.oauth.did }]);
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
  expect(fixture.events).toEqual([]);
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

it("notifies the current viewer after a partially successful public import", async () => {
  const fixture = setup();
  const write = spyOn(client,"writePodcastSubscription").mockResolvedValue();
  const request = spyOn(client,"podcastRequest").mockImplementation(async <T,>(_oauth:OAuthSession,path:string,_method?:string,body?:unknown):Promise<T> => {
    if(path==="shows")return {shows:[]} as T;
    if((body as {url?:string})?.url?.includes("failed"))throw new Error("Resolve Failed");
    return {show:{id:"imported",title:"Imported",sourceKind:"rss"}} as T;
  });
  restores.push(()=>write.mockRestore(),()=>request.mockRestore());
  const {result}=renderHook(()=>useImportOpmlPodcasts(false),{wrapper:fixture.wrapper});
  await act(async()=>{await result.current.importer.mutateAsync({feeds:[{...feed,feedUrl:"https://example.org/feed"},{...feed,feedUrl:"https://failed.example.org/feed"}],privateFeeds:false,onProgress(){}});});
  expect(write).toHaveBeenCalledTimes(1);
  expect(fixture.events).toEqual([{viewerDid:fixture.oauth.did}]);
  await waitFor(()=>expect(result.current.importer.data?.failed).toHaveLength(1));
});
