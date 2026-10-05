import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as playerModule from "@/components/Podcasts/PodcastPlayerProvider";
import * as client from "@/lib/podcasts/client";
import * as offline from "@/lib/podcasts/offline";
import { PodcastLibrary } from "@/components/Podcasts/PodcastLibrary";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

it("adds a tokenized private RSS feed without a public subscription write", async () => {
  const oauth = {} as OAuthSession;
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
