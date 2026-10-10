import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { act, useState } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as playerModule from "@/components/Podcasts/PodcastPlayerProvider";
import * as client from "@/lib/podcasts/client";
import * as device from "@/lib/podcasts/deviceDownload";
import * as offline from "@/lib/podcasts/offline";
import { PodcastLibrary } from "@/components/Podcasts/PodcastLibrary";

const restores: (() => void)[] = [];
beforeEach(() => {
  for (const name of ["HTMLElement", "Element", "Node", "MutationObserver", "DOMRect", "getComputedStyle"] as const) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    const value = name === "getComputedStyle" ? window.getComputedStyle.bind(window) : window[name];
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
  for (const [name, value] of Object.entries({ requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); restores.splice(0).reverse().forEach(restore => restore()); });

it("adds a tokenized private RSS feed without a public subscription write", async () => {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const getOAuthSession = () => oauth;
  const state = client.initialPodcastState();
  const changes: Partial<client.PodcastState>[] = [];
  const requestPaths: string[] = [];
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: "did:plc:viewer" }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const player = spyOn(playerModule, "usePodcastPlayer").mockReturnValue({
    state, episode: null, playing: false, position: 0, duration: 0, error: null, silence: null,
    play: async () => {}, toggle() {}, seek() {}, setRemoveSilences: async () => {}, clearError() {},
    changeState: async patch => { changes.push(patch); },
  });
  const local = spyOn(offline, "listPodcastDownloads").mockResolvedValue([]);
  const write = spyOn(client, "writePodcastSubscription").mockResolvedValue();
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string): Promise<T> => {
    requestPaths.push(path);
    if (path === "private/resolve") return { show: { id: "private-show", title: "Members Podcast", sourceKind: "private-rss", visibility: "private" }, episodes: [] } as T;
    if (path === "shows") return { shows: [] } as T;
    return { episodes: [] } as T;
  });
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => write.mockRestore(), () => request.mockRestore());
  render(<PodcastLibrary />);
  const add = screen.getByRole("button", { name: "Add a Podcast" });
  expect(add.className).toContain("min-h-7");
  expect(add.className).toContain("pointer-coarse:min-h-11");
  expect(add.querySelector("svg")?.getAttribute("aria-hidden")).toBe("true");
  fireEvent.click(add);
  fireEvent.click(screen.getByRole("checkbox", { name: "Private Feed" }));
  const input = screen.getByLabelText("Private RSS Feed URL");
  fireEvent.change(input, { target: { value: "https://members.example/feed?token=secret" } });
  fireEvent.submit(input.closest("form")!);
  await waitFor(() => expect(requestPaths).toContain("private/resolve"));
  await waitFor(() => expect(changes).toEqual([{ subscriptions: ["private-show"] }]));
  expect(write).not.toHaveBeenCalled();
  expect(requestPaths).not.toContain("resolve");
  expect(screen.queryByText("Map RSS to AT Protocol")).toBeNull();
  expect(screen.getByRole("complementary", { name: "Podcast Library" }).className).toContain("rounded-xl");
  expect(screen.getByRole("complementary", { name: "Podcast Library" }).className).toContain("p-3");
  expect(screen.getByRole("button", { name: "Recently Added" }).className).toContain("min-h-8");
  expect(screen.getByRole("button", { name: "Recently Added" }).className).toContain("pointer-coarse:min-h-11");
});

it("seeks current episode notes without reloading and starts other episode notes at their selected time", async () => {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const getOAuthSession = () => oauth;
  const current: client.PodcastEpisode = { id: "current", showId: "show", title: "Current Episode", audioUrl: "/current", durationSeconds: 120, publishedAt: "2026-10-05", transcripts: [], description: "0:30 Current Topic" };
  const other = { ...current, id: "other", title: "Other Episode", audioUrl: "/other", description: "1:00 Other Topic" };
  const played: unknown[] = [];
  const sought: number[] = [];
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const player = spyOn(playerModule, "usePodcastPlayer").mockReturnValue({ state: client.initialPodcastState(), episode: current, playing: false, position: 0, duration: 120, error: null, silence: null, play: async (item, startAt) => { played.push([item.id, startAt]); }, seek: seconds => { sought.push(seconds); }, toggle() {}, setRemoveSilences: async () => {}, clearError() {}, changeState: async () => {} });
  const local = spyOn(offline, "listPodcastDownloads").mockResolvedValue([]);
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string): Promise<T> => (path === "shows" ? { shows: [] } : { episodes: [current, other] }) as T);
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => request.mockRestore());
  render(<PodcastLibrary />);
  fireEvent.click(await screen.findByRole("button", { name: "Show Notes: Current Episode" }));
  fireEvent.click(within(await screen.findByRole("dialog")).getByRole("button", { name: "Seek to 0:30" }));
  expect(sought).toEqual([30]);
  expect(played).toEqual([]);
  fireEvent.click(screen.getByRole("button", { name: "Close" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  fireEvent.click(screen.getByRole("button", { name: "Show Notes: Other Episode" }));
  fireEvent.click(within(await screen.findByRole("dialog")).getByRole("button", { name: "Seek to 1:00" }));
  expect(played).toEqual([["other", 60]]);
  expect(sought).toEqual([30]);
});

it("offers device audio saving from viewer-owned offline downloads without an OAuth session", async () => {
  const state = client.initialPodcastState();
  const getOAuthSession = () => null;
  const played: client.PodcastEpisode[] = [];
  const patches: Partial<client.PodcastState>[] = [];
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: "did:plc:viewer" }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const player = spyOn(playerModule, "usePodcastPlayer").mockReturnValue({
    state, episode: null, playing: false, position: 0, duration: 0, error: null, silence: null,
    play: async item => { played.push(item); }, toggle() {}, seek() {}, setRemoveSilences: async () => {}, clearError() {}, changeState: async patch => { patches.push(patch); },
  });
  const item: client.PodcastEpisode = { id: "downloaded", title: "Offline Episode", showId: "show", audioUrl: "/media", publishedAt: "2026-10-05", transcripts: [] };
  const local = spyOn(offline, "listPodcastDownloads").mockResolvedValue([{ episode: item, downloadedAt: "2026-10-05", bytes: 10 }]);
  const save = spyOn(device, "savePodcastAudioToDevice").mockResolvedValue("saved");
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => save.mockRestore());
  render(<PodcastLibrary />);
  await waitFor(() => expect(screen.getByRole("button", { name: /Downloaded/ }).textContent).toContain("1"));
  fireEvent.click(screen.getByRole("button", { name: /Downloaded/ }));
  await screen.findByRole("button", { name: "Save Audio" });
  for (const label of ["Play", "Add to Queue", "Mark Played", "Save Audio", "Delete Download"]) {
    const action = screen.getByRole("button", { name: label });
    expect(action.querySelector("svg")?.getAttribute("aria-hidden")).toBe("true");
  }
  fireEvent.click(screen.getByRole("button", { name: "Play" }));
  fireEvent.click(screen.getByRole("button", { name: "Add to Queue" }));
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(played).toEqual([item]);
  expect(patches).toEqual([{ queue: [item.id] }]);
  fireEvent.click(screen.getByRole("button", { name: "Save Audio" }));
  await waitFor(() => expect(save).toHaveBeenCalled());
  expect(save.mock.calls[0]?.[0]).toBe("did:plc:viewer");
  expect(save.mock.calls[0]?.[1]).toEqual(item);
  expect(await screen.findByText("Saved to Device")).toBeTruthy();
});

it("searches subscribed shows and episodes, clears to the feed, and opens a matching show", async () => {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const getOAuthSession = () => oauth;
  const state = { ...client.initialPodcastState(), subscriptions: ["show"] };
  const changes: Partial<client.PodcastState>[] = [];
  const write = spyOn(client, "writePodcastSubscription").mockResolvedValue();
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: "did:plc:viewer" }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const player = spyOn(playerModule, "usePodcastPlayer").mockReturnValue({ state, episode: null, playing: false, position: 0, duration: 0, error: null, silence: null, play: async () => {}, toggle() {}, seek() {}, setRemoveSilences: async () => {}, clearError() {}, changeState: async patch => { changes.push(patch); } });
  const local = spyOn(offline, "listPodcastDownloads").mockResolvedValue([]);
  const show: client.PodcastShow = { id: "show", title: "Science Show", sourceKind: "rss" };
  const item = (id: string, title: string): client.PodcastEpisode => ({ id, title, showId: "show", audioUrl: "/media", publishedAt: "2026-10-05", transcripts: [] });
  const requests: string[] = [];
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string): Promise<T> => {
    requests.push(path);
    if (path === "shows") return { shows: [show] } as T;
    if (path === "search") return { shows: [show], episodes: [item("match", "Matched Science Episode")], hasMore: false } as T;
    return { episodes: [item("recent", path.includes("showId") ? "Show Episode" : "Recent Episode")] } as T;
  });
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => request.mockRestore(), () => write.mockRestore());
  render(<PodcastLibrary />);
  await screen.findByText("Recent Episode");
  expect(screen.getByText("Recent Episode").closest("li")?.firstElementChild?.firstElementChild?.firstElementChild?.textContent).toBe(show.title);
  expect(screen.queryByRole("group", { name: "Podcast Search Scope" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Library" })).toBeNull();
  expect(screen.getAllByRole("button", { name: "Search" })).toHaveLength(1);
  const input = screen.getByRole("searchbox", { name: "Search Your Library" });
  fireEvent.change(input, { target: { value: "science" } });
  await screen.findByText("Matched Science Episode");
  expect(screen.getByText("Matched Science Episode").closest("li")?.firstElementChild?.firstElementChild?.firstElementChild?.textContent).toBe(show.title);
  expect(screen.queryByText("Recent Episode")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Clear Search" }));
  await screen.findByText("Recent Episode");
  fireEvent.change(input, { target: { value: "science" } });
  const results = await screen.findByRole("region", { name: "Matching Shows" });
  fireEvent.click(results.querySelector("button")!);
  await screen.findByText("Show Episode");
  expect((screen.getByRole("searchbox", { name: "Search This Show" }) as HTMLInputElement).value).toBe("");
  expect(requests).toContain("episodes?showId=show");
  const showHeader = screen.getByRole("heading", { name: show.title }).closest("header")!;
  const unsubscribe = within(showHeader).getByRole("button", { name: "Unsubscribe" });
  expect(screen.getAllByRole("button", { name: "Unsubscribe" })).toHaveLength(1);
  expect(unsubscribe.className).toContain("min-h-8");
  expect(unsubscribe.className).toContain("pointer-coarse:min-h-11");
  fireEvent.click(unsubscribe);
  await waitFor(() => expect(write).toHaveBeenCalledWith(oauth, oauth.did, show, true));
  expect(changes).toEqual([{ subscriptions: [] }]);
});

it("labels mixed episode cards with their podcast names across recent, downloads, and queue feeds", async () => {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const getOAuthSession = () => oauth;
  const state = { ...client.initialPodcastState(), queue: ["recent", "offline"] };
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const player = spyOn(playerModule, "usePodcastPlayer").mockReturnValue({ state, episode: null, playing: false, position: 0, duration: 0, error: null, silence: null, play: async () => {}, toggle() {}, seek() {}, setRemoveSilences: async () => {}, clearError() {}, changeState: async () => {} });
  const episode = (id: string, showId: string): client.PodcastEpisode => ({ id, showId, title: `${id} Episode`, audioUrl: "/media", publishedAt: "2026-10-05", transcripts: [] });
  const recent = episode("recent", "primary");
  const unknown = episode("unknown", "unavailable");
  const blank = episode("blank", "blank");
  const downloaded = episode("offline", "private");
  const local = spyOn(offline, "listPodcastDownloads").mockResolvedValue([{ episode: downloaded, downloadedAt: "2026-10-05", bytes: 10 }]);
  const paths: string[] = [];
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string): Promise<T> => {
    paths.push(path);
    if (path === "shows") return { shows: [
      { id: "primary", title: "Primary Technology", sourceKind: "rss" },
      { id: "private", title: "Members Podcast", sourceKind: "private-rss", visibility: "private" },
      { id: "blank", title: "   ", sourceKind: "rss" },
    ] } as T;
    return { episodes: [recent, unknown, blank] } as T;
  });
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => request.mockRestore());
  render(<PodcastLibrary />);
  await screen.findByText(recent.title);
  expect(screen.getByText(recent.title).closest("li")?.firstElementChild?.firstElementChild?.firstElementChild?.textContent).toBe("Primary Technology");
  for (const item of [unknown, blank]) {
    expect(screen.getByText(item.title).closest("li")?.firstElementChild?.firstElementChild?.textContent).toBe("Unplayed");
  }
  fireEvent.click(screen.getByRole("button", { name: /Downloaded/ }));
  await screen.findByText(downloaded.title);
  expect(screen.getByText(downloaded.title).closest("li")?.firstElementChild?.firstElementChild?.firstElementChild?.textContent).toBe("Members Podcast");
  fireEvent.click(screen.getByRole("button", { name: /Up Next/ }));
  await screen.findByText(recent.title);
  expect(screen.getByText(recent.title).closest("li")?.firstElementChild?.firstElementChild?.firstElementChild?.textContent).toBe("Primary Technology");
  expect(screen.getByText(downloaded.title).closest("li")?.firstElementChild?.firstElementChild?.firstElementChild?.textContent).toBe("Members Podcast");
  expect(paths.filter(path => path === "shows")).toHaveLength(1);
  expect(paths.every(path => path === "shows" || path.startsWith("episodes"))).toBe(true);
});

it("clears private library terms before directory search and previews before explicit subscription", async () => {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const getOAuthSession = () => oauth;
  const state = client.initialPodcastState();
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const changes: Partial<client.PodcastState>[] = [];
  const player = spyOn(playerModule, "usePodcastPlayer").mockReturnValue({ state, episode: null, playing: false, position: 0, duration: 0, error: null, silence: null, play: async () => {}, toggle() {}, seek() {}, setRemoveSilences: async () => {}, clearError() {}, changeState: async patch => { changes.push(patch); } });
  const local = spyOn(offline, "listPodcastDownloads").mockResolvedValue([]);
  const write = spyOn(client, "writePodcastSubscription").mockResolvedValue();
  const requests: { path: string; method?: string; body?: unknown }[] = [];
  const show: client.PodcastShow = { id: "discovered", title: "Discovered Science", sourceKind: "rss", feedUrl: "https://example.org/feed" };
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string, method?: string, body?: unknown): Promise<T> => {
    requests.push({ path, method, body });
    if (path === "shows") return { shows: [] } as T;
    if (path === "search") return { shows: [], episodes: [], hasMore: false, candidates: [{ provider: "podcastindex", id: "pi:1", title: show.title, feedUrl: show.feedUrl, description: "<b>Public Show</b>" }], directoryLimit: 50 } as T;
    if (path === "resolve") return { show, episodes: [] } as T;
    return { episodes: [] } as T;
  });
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => write.mockRestore(), () => request.mockRestore());
  render(<PodcastLibrary />);
  fireEvent.change(screen.getByRole("searchbox"), { target: { value: "private library terms" } });
  fireEvent.click(within(screen.getByRole("complementary", { name: "Podcast Library" })).getByRole("button", { name: "Search" }));
  const input = screen.getByRole("searchbox", { name: "Search Podcasts" }) as HTMLInputElement;
  expect(input.value).toBe("");
  expect(requests.some(request => request.path === "search")).toBe(false);
  fireEvent.change(input, { target: { value: "science" } });
  await screen.findByText(show.title);
  expect(requests.find(request => request.path === "search")?.body).toEqual({ query: "science", scope: "directory", limit: 50 });
  expect(screen.getByRole("link", { name: "Podcast Index" }).getAttribute("href")).toBe("https://podcastindex.org");
  expect(write).not.toHaveBeenCalled();
  expect(changes).toEqual([]);
  fireEvent.click(screen.getByRole("button", { name: "Preview Podcast" }));
  await screen.findByRole("button", { name: "Subscribe" });
  expect(requests.find(request => request.path === "resolve")?.body).toEqual({ url: show.feedUrl });
  expect(write).not.toHaveBeenCalled();
  const showHeader = screen.getByRole("heading", { name: show.title }).closest("header")!;
  const subscribe = within(showHeader).getByRole("button", { name: "Subscribe" });
  expect(screen.getAllByRole("button", { name: "Subscribe" })).toHaveLength(1);
  expect(subscribe.className).toContain("min-h-8");
  expect(subscribe.className).toContain("pointer-coarse:min-h-11");
  fireEvent.click(subscribe);
  await waitFor(() => expect(write).toHaveBeenCalledWith(oauth, oauth.did, show, false));
  expect(changes).toEqual([{ subscriptions: [show.id] }]);
  const sidebar = within(screen.getByRole("complementary", { name: "Podcast Library" }));
  fireEvent.click(sidebar.getByRole("button", { name: "Search" }));
  fireEvent.change(screen.getByRole("searchbox", { name: "Search Podcasts" }), { target: { value: "another discovery query" } });
  expect(sidebar.getByRole("button", { name: "Search" }).getAttribute("aria-current")).toBe("page");
  expect(sidebar.getByRole("button", { name: "Recently Added" }).getAttribute("aria-current")).toBeNull();
  fireEvent.click(sidebar.getByRole("button", { name: "Recently Added" }));
  const libraryInput = screen.getByRole("searchbox", { name: "Search Your Library" }) as HTMLInputElement;
  expect(libraryInput.value).toBe("");
  expect(sidebar.getByRole("button", { name: "Recently Added" }).getAttribute("aria-current")).toBe("page");
  expect(sidebar.getByRole("button", { name: "Search" }).getAttribute("aria-current")).toBeNull();
  expect(screen.queryByRole("link", { name: "Podcast Index" })).toBeNull();
  expect(screen.queryByRole("group", { name: "Podcast Search Scope" })).toBeNull();
});

it("updates Played indicators while preserving episode positions and usable playback and notes", async () => {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const getOAuthSession = () => oauth;
  const changes: Partial<client.PodcastState>[] = [];
  const playback: string[] = [];
  const initial = client.initialPodcastState();
  initial.progress.finished = { positionSeconds: 120, completed: true, updatedAt: "2026-10-05T00:00:00Z" };
  initial.progress.fresh = { positionSeconds: 35, completed: false, updatedAt: "2026-10-05T00:00:00Z" };
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const player = spyOn(playerModule, "usePodcastPlayer").mockImplementation(function useFixturePlayer() {
    const [state, setState] = useState(initial);
    return {
      state, episode: null, playing: false, position: 0, duration: 0, error: null, silence: null,
      play: async item => { playback.push(item.id); }, toggle() {}, seek() {}, setRemoveSilences: async () => {}, clearError() {},
      changeState: async patch => {
        changes.push(patch);
        setState(current => ({ ...current, ...patch, progress: { ...current.progress, ...patch.progress } }));
      },
    };
  });
  const episodes: client.PodcastEpisode[] = ["finished", "fresh"].map(id => ({ id, showId: "show", title: id === "finished" ? "Finished Episode" : "Fresh Episode", audioUrl: `/${id}`, durationSeconds: 120, publishedAt: "2026-10-05", transcripts: [], description: "Publisher show notes" }));
  const local = spyOn(offline, "listPodcastDownloads").mockResolvedValue([]);
  const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string): Promise<T> => (path === "shows" ? { shows: [{ id: "show", title: "My Podcast", sourceKind: "rss" }] } : { episodes }) as T);
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => request.mockRestore());
  render(<PodcastLibrary />);
  const finished = (await screen.findByRole("button", { name: "Show Notes: Finished Episode" })).closest("li")!;
  const fresh = screen.getByRole("button", { name: "Show Notes: Fresh Episode" }).closest("li")!;
  expect(finished.getAttribute("data-played")).toBe("true");
  expect(within(finished).getByText("Played")).toBeTruthy();
  expect(within(fresh).getByText("Unplayed")).toBeTruthy();
  fireEvent.click(within(fresh).getByRole("button", { name: "Mark Played" }));
  await waitFor(() => expect(within(fresh).getByText("Played")).toBeTruthy());
  expect(fresh.getAttribute("data-played")).toBe("true");
  expect(within(fresh).getByRole("heading").classList.contains("text-muted-foreground")).toBe(true);
  expect(changes[0]?.progress?.fresh?.positionSeconds).toBe(35);
  expect(changes[0]?.progress?.fresh?.completed).toBe(true);
  expect(within(finished).getByText("Played")).toBeTruthy();
  fireEvent.click(within(fresh).getByRole("button", { name: "Play" }));
  expect(playback).toEqual(["fresh"]);
  expect(within(fresh).getByRole("button", { name: "Play" }).hasAttribute("disabled")).toBe(false);
  fireEvent.click(within(fresh).getByRole("button", { name: "Mark Unplayed" }));
  await waitFor(() => expect(within(fresh).getByText("Unplayed")).toBeTruthy());
  expect(fresh.getAttribute("data-played")).toBe("false");
  expect(within(fresh).getByRole("heading").classList.contains("text-muted-foreground")).toBe(false);
  expect(changes[1]?.progress?.fresh?.positionSeconds).toBe(35);
  expect(changes[1]?.progress?.fresh?.completed).toBe(false);
  expect(within(finished).getByText("Played")).toBeTruthy();
  fireEvent.click(within(finished).getByRole("button", { name: "Show Notes: Finished Episode" }));
  expect(within(await screen.findByRole("dialog")).getByText("Publisher show notes")).toBeTruthy();
});
