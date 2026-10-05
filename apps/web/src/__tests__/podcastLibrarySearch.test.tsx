import { afterEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as client from "@/lib/podcasts/client";
import { usePodcastLibrarySearch, type PodcastSearchPage } from "@/hooks/usePodcastLibrarySearch";

const oauth = { did: "did:one" } as unknown as OAuthSession;
const getOAuthSession = () => oauth;
const episode = (id: string, title = id): client.PodcastEpisode => ({ id, title, showId: "show", audioUrl: "/media", publishedAt: "2026-10-05", transcripts: [] });
const empty: PodcastSearchPage = { shows: [], episodes: [], hasMore: false };
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function online() {
  const previous = Object.getOwnPropertyDescriptor(navigator, "onLine");
  Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
  restores.push(() => { if (previous) Object.defineProperty(navigator, "onLine", previous); else Reflect.deleteProperty(navigator, "onLine"); });
}

it("aborts old queries and excludes late replies after query and viewer changes", async () => {
  online();
  const pending: { resolve: (page: PodcastSearchPage) => void; signal?: AbortSignal }[] = [];
  const request = spyOn(client, "podcastRequest").mockImplementation(<T,>(_oauth: OAuthSession, _path: string, _method?: string, _body?: unknown, signal?: AbortSignal): Promise<T> => new Promise(resolve => pending.push({ resolve: page => resolve(page as T), signal })));
  restores.push(() => request.mockRestore());
  const { result, rerender, unmount } = renderHook(({ viewer, query }) => usePodcastLibrarySearch({ viewer, query, getOAuthSession: () => ({ did: viewer }) as OAuthSession }), { initialProps: { viewer: "did:one", query: "first" } });
  await waitFor(() => expect(pending).toHaveLength(1));
  rerender({ viewer: "did:one", query: "second" });
  expect(pending[0].signal?.aborted).toBe(true);
  await waitFor(() => expect(pending).toHaveLength(2));
  await act(async () => pending[1].resolve({ ...empty, episodes: [episode("new")] }));
  await act(async () => pending[0].resolve({ ...empty, episodes: [episode("old")] }));
  expect(result.current.episodes.map(item => item.id)).toEqual(["new"]);
  rerender({ viewer: "did:two", query: "second" });
  expect(result.current.episodes).toEqual([]);
  await waitFor(() => expect(pending).toHaveLength(3));
  unmount();
  expect(pending[2].signal?.aborted).toBe(true);
});

it("continues an empty bounded page and deduplicates subsequent pages", async () => {
  online();
  const bodies: unknown[] = [];
  const replies = [ { ...empty, hasMore: true, cursor: "scan-500" }, { ...empty, episodes: [episode("one")], hasMore: true, cursor: "scan-1000" }, { ...empty, episodes: [episode("one"), episode("two")] } ];
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string, _method?: string, body?: unknown): Promise<T> => { expect(path).toBe("search"); bodies.push(body); return replies.shift() as T; });
  restores.push(() => request.mockRestore());
  const { result } = renderHook(() => usePodcastLibrarySearch({ viewer: "did:one", query: "science", showId: "show", getOAuthSession }));
  await waitFor(() => expect(result.current.hasMore).toBe(true));
  expect(result.current.episodes).toEqual([]);
  await act(async () => result.current.loadMore());
  await act(async () => result.current.loadMore());
  expect(result.current.episodes.map(item => item.id)).toEqual(["one", "two"]);
  expect(bodies).toEqual([{ query: "science", scope: "library", kind: "all", showId: "show", limit: 20 }, { query: "science", scope: "library", kind: "all", showId: "show", limit: 20, cursor: "scan-500" }, { query: "science", scope: "library", kind: "all", showId: "show", limit: 20, cursor: "scan-1000" }]);
});

it("searches only downloaded metadata locally and validates short queries", async () => {
  const request = spyOn(client, "podcastRequest");
  restores.push(() => request.mockRestore());
  const downloaded = [episode("one", "Café Science"), episode("two", "Other")];
  const { result, rerender } = renderHook(({ query }) => usePodcastLibrarySearch({ viewer: "did:offline", query, downloaded, getOAuthSession: () => null }), { initialProps: { query: "cafe science" } });
  await waitFor(() => expect(result.current.episodes.map(item => item.id)).toEqual(["one"]));
  expect(request).not.toHaveBeenCalled();
  rerender({ query: "x" });
  expect(result.current.valid).toBe(false);
  expect(result.current.episodes).toEqual([]);
});

it("exposes failure and supports explicit retry", async () => {
  online();
  const request = spyOn(client, "podcastRequest").mockRejectedValueOnce(new Error("Unavailable")).mockResolvedValue(empty);
  restores.push(() => request.mockRestore());
  const { result } = renderHook(() => usePodcastLibrarySearch({ viewer: "did:one", query: "science", getOAuthSession }));
  await waitFor(() => expect(result.current.error).toBe("Unavailable"));
  act(() => result.current.retry());
  await waitFor(() => expect(result.current.error).toBeNull());
  await waitFor(() => expect(request).toHaveBeenCalledTimes(2));
  await waitFor(() => expect(result.current.loading).toBe(false));
});

 it("refuses a stale OAuth identity during account switching", async () => {
  online();
  const request = spyOn(client, "podcastRequest");
  restores.push(() => request.mockRestore());
  const { result } = renderHook(() => usePodcastLibrarySearch({ viewer: "did:bob", query: "private", getOAuthSession }));
  await waitFor(() => expect(result.current.error).toBe("Account Is Loading. Please Retry Search."));
  expect(result.current.episodes).toEqual([]);
  expect(request).not.toHaveBeenCalled();
});

it("sends only explicit directory queries, excludes library parameters, and stops directory paging", async () => {
  online();
  const request = spyOn(client, "podcastRequest").mockResolvedValue({ ...empty, candidates: [{ provider: "podcastindex", id: "pi:1", title: "Science", feedUrl: "https://example.org/feed" }], directoryLimit: 50 });
  restores.push(() => request.mockRestore());
  const downloaded = [episode("private")];
  const { result, rerender } = renderHook(({ query, scope }: { query: string; scope: "library" | "directory" }) => usePodcastLibrarySearch({ viewer: "did:one", query, scope, showId: "private-show", downloaded, getOAuthSession }), { initialProps: { query: "", scope: "directory" } });
  expect(request).not.toHaveBeenCalled();
  rerender({ query: "science", scope: "directory" });
  await waitFor(() => expect(result.current.candidates).toHaveLength(1));
  expect(request).toHaveBeenCalledWith(oauth, "search", "POST", { query: "science", scope: "directory", limit: 50 }, expect.any(AbortSignal));
  expect(result.current.episodes).toEqual([]);
  await act(async () => result.current.loadMore());
  expect(request).toHaveBeenCalledTimes(1);
  rerender({ query: "", scope: "library" });
  expect(result.current.candidates).toBeUndefined();
});

it("cancels directory replies when switching back to a library query", async () => {
  online();
  const pending: { resolve: (page: PodcastSearchPage) => void; signal?: AbortSignal }[] = [];
  const request = spyOn(client, "podcastRequest").mockImplementation(<T,>(_oauth: OAuthSession, _path: string, _method?: string, _body?: unknown, signal?: AbortSignal): Promise<T> => new Promise(resolve => pending.push({ resolve: page => resolve(page as T), signal })));
  restores.push(() => request.mockRestore());
  const { result, rerender } = renderHook(({ scope }: { scope: "library" | "directory" }) => usePodcastLibrarySearch({ viewer: "did:one", query: "science", scope, getOAuthSession }), { initialProps: { scope: "directory" } });
  await waitFor(() => expect(pending).toHaveLength(1));
  rerender({ scope: "library" });
  expect(pending[0].signal?.aborted).toBe(true);
  await waitFor(() => expect(pending).toHaveLength(2));
  await act(async () => pending[1].resolve({ ...empty, episodes: [episode("library")] }));
  await act(async () => pending[0].resolve({ ...empty, candidates: [{ provider: "podcastindex", id: "pi:1", title: "Science", feedUrl: "https://example.org/feed" }] }));
  expect(result.current.episodes.map(item => item.id)).toEqual(["library"]);
  expect(result.current.candidates).toBeUndefined();
});
