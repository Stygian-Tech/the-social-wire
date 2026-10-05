import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as playerModule from "@/components/Podcasts/PodcastPlayerProvider";
import * as client from "@/lib/podcasts/client";
import * as device from "@/lib/podcasts/deviceDownload";
import * as offline from "@/lib/podcasts/offline";
import { PodcastLibrary } from "@/components/Podcasts/PodcastLibrary";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

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
  fireEvent.click(screen.getByRole("button", { name: "Add a Podcast" }));
  fireEvent.click(screen.getByRole("checkbox", { name: "Private Feed" }));
  const input = screen.getByLabelText("Private RSS Feed URL");
  fireEvent.change(input, { target: { value: "https://members.example/feed?token=secret" } });
  fireEvent.submit(input.closest("form")!);
  await waitFor(() => expect(requestPaths).toContain("private/resolve"));
  await waitFor(() => expect(changes).toEqual([{ subscriptions: ["private-show"] }]));
  expect(write).not.toHaveBeenCalled();
  expect(requestPaths).not.toContain("resolve");
  expect(screen.queryByText("Map RSS to AT Protocol")).toBeNull();
  expect(screen.getByRole("complementary", { name: "Podcast Library" })).toBeTruthy();
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
  const useAuth = spyOn(auth, "useAuth").mockReturnValue({ session: { did: "did:plc:viewer" }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const player = spyOn(playerModule, "usePodcastPlayer").mockReturnValue({ state, episode: null, playing: false, position: 0, duration: 0, error: null, silence: null, play: async () => {}, toggle() {}, seek() {}, setRemoveSilences: async () => {}, clearError() {}, changeState: async () => {} });
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
  restores.push(() => useAuth.mockRestore(), () => player.mockRestore(), () => local.mockRestore(), () => request.mockRestore());
  render(<PodcastLibrary />);
  await screen.findByText("Recent Episode");
  const input = screen.getByRole("searchbox", { name: "Search Your Library" });
  fireEvent.change(input, { target: { value: "science" } });
  await screen.findByText("Matched Science Episode");
  expect(screen.queryByText("Recent Episode")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Clear Search" }));
  await screen.findByText("Recent Episode");
  fireEvent.change(input, { target: { value: "science" } });
  const results = await screen.findByRole("region", { name: "Matching Shows" });
  fireEvent.click(results.querySelector("button")!);
  await screen.findByText("Show Episode");
  expect((screen.getByRole("searchbox", { name: "Search This Show" }) as HTMLInputElement).value).toBe("");
  expect(requests).toContain("episodes?showId=show");
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
  fireEvent.click(within(screen.getByRole("complementary", { name: "Podcast Library" })).getByRole("button", { name: "Discover" }));
  const input = screen.getByRole("searchbox", { name: "Discover Podcasts" }) as HTMLInputElement;
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
  fireEvent.click(screen.getByRole("button", { name: "Subscribe" }));
  await waitFor(() => expect(write).toHaveBeenCalledWith(oauth, oauth.did, show, false));
  expect(changes).toEqual([{ subscriptions: [show.id] }]);
});
