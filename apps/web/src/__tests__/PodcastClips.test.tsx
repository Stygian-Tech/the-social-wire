import { afterEach, describe, expect, it, spyOn } from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as authStorage from "@/lib/auth";
import * as client from "@/lib/podcasts/client";
import * as player from "@/components/Podcasts/PodcastPlayerProvider";
import { PodcastClips } from "@/components/Podcasts/PodcastClips";
const restores: (() => void)[] = [];
afterEach(() => {
  cleanup();
  for (const restore of restores.splice(0).reverse()) restore();
});
describe("Static podcast clip exports", () => {
  it("prepares a static artwork export without changing caption frames", async () => {
      const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
      const stored = spyOn(authStorage, "getStoredOAuthDid").mockReturnValue(oauth.did);
      restores.push(() => stored.mockRestore());
      const getOAuthSession = () => oauth;
      const authSpy = spyOn(auth, "useAuth").mockReturnValue({
        session: { did: "did:plc:viewer" },
        getOAuthSession,
      } as ReturnType<typeof auth.useAuth>);
      const playerSpy = spyOn(player, "usePodcastPlayer").mockReturnValue({
        duration: 120,
        position: 0,
        playing: false,
      } as ReturnType<typeof player.usePodcastPlayer>);
      const requests = spyOn(client, "podcastRequest").mockResolvedValue({
        clips: [],
      });
      restores.push(
        () => authSpy.mockRestore(),
        () => playerSpy.mockRestore(),
        () => requests.mockRestore(),
      );
      render(
        <PodcastClips
          episode={{
            id: "episode",
            showId: "show",
            title: "Episode",
            audioUrl: "https://publisher.example/audio.mp3",
            durationSeconds: 120,
            publishedAt: "2026-10-04T12:00:00Z",
            transcripts: [],
          }}
        />,
      );
      expect(screen.queryByRole("checkbox", { name: /Include Captions/ })).toBeNull();
      fireEvent.click(screen.getByRole("button", { name: "Prepare Exports" }));
      await waitFor(() =>
        expect(requests).toHaveBeenCalledWith(
          oauth,
          "clips",
          "POST",
          expect.objectContaining({
            includeCaptions: false,
            startSeconds: 0,
            endSeconds: 30,
          }),
        ),
      );
  });
});

const episode = { id: "episode", showId: "show", title: "Episode", audioUrl: "https://publisher.example/audio.mp3", durationSeconds: 120, publishedAt: "2026-10-04T12:00:00Z", transcripts: [] };
const draft: client.PodcastClip = { id: "draft", episodeId: episode.id, title: "Alice Private Draft", startSeconds: 0, endSeconds: 30, status: "pending", createdAt: "2026-10-05" };
function clipFixture() {
  const oauth = { did: "did:alice" } as unknown as OAuthSession;
  const stored = spyOn(authStorage, "getStoredOAuthDid").mockReturnValue(oauth.did);
  restores.push(() => stored.mockRestore());
  const getOAuthSession = () => oauth;
  const authSpy = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof auth.useAuth>);
  const playerSpy = spyOn(player, "usePodcastPlayer").mockReturnValue({ duration: 120, position: 0, playing: false } as ReturnType<typeof player.usePodcastPlayer>);
  let refresh: () => void = () => {};
  const realSetInterval = globalThis.setInterval;
  const timer = spyOn(globalThis, "setInterval").mockImplementation(((callback: () => void, delay?: number) => {
    if (delay === 5000) { refresh = callback; return 1; }
    return realSetInterval(callback, delay);
  }) as typeof setInterval);
  const realClearInterval = globalThis.clearInterval;
  const clear = spyOn(globalThis, "clearInterval").mockImplementation(id => { if (id !== 1) realClearInterval(id as number | undefined); });
  restores.push(() => authSpy.mockRestore(), () => playerSpy.mockRestore(), () => timer.mockRestore(), () => clear.mockRestore());
  return { oauth, getOAuthSession, authSpy, refresh: () => refresh() };
}

it("clears a transient polling error after recovery without exposing raw fetch failures", async () => {
  const fixture = clipFixture();
  const requests = spyOn(client, "podcastRequest").mockRejectedValueOnce(new TypeError("Failed to fetch https://private.example?token=secret")).mockResolvedValue({ clips: [draft] });
  restores.push(() => requests.mockRestore());
  render(<PodcastClips episode={episode} />);
  await screen.findByText("Clips Could Not Load. Retrying…");
  expect(screen.queryByText(/token=secret/)).toBeNull();
  fixture.refresh();
  await screen.findByText(draft.title);
  await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
});

it("discards an old account's pending response and hides its drafts on viewer switch", async () => {
  const fixture = clipFixture();
  let resolve: (value: { clips: client.PodcastClip[] }) => void = () => {};
  let signal: AbortSignal | undefined;
  const requests = spyOn(client, "podcastRequest").mockImplementation(<T,>(_oauth: OAuthSession, _path: string, _method?: string, _body?: unknown, nextSignal?: AbortSignal) => {
    signal = nextSignal;
    return new Promise<T>(done => { resolve = value => done(value as T); });
  });
  restores.push(() => requests.mockRestore());
  const view = render(<PodcastClips episode={episode} />);
  await waitFor(() => expect(requests).toHaveBeenCalledTimes(1));
  fixture.authSpy.mockReturnValue({ session: { did: "did:bob" }, getOAuthSession: fixture.getOAuthSession } as ReturnType<typeof auth.useAuth>);
  view.rerender(<PodcastClips episode={episode} />);
  expect(signal?.aborted).toBe(true);
  resolve({ clips: [draft] });
  await waitFor(() => expect(screen.queryByText(draft.title)).toBeNull());
  expect(requests).toHaveBeenCalledTimes(1);
  fireEvent.click(screen.getByRole("button", { name: "Prepare Exports" }));
  await screen.findByText("Account Is Loading. Please Retry.");
  expect(requests).toHaveBeenCalledTimes(1);
});

it("keeps action failures visible when background polling succeeds", async () => {
  const fixture = clipFixture();
  const requests = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, _path: string, method?: string): Promise<T> => {
    if (method === "POST") throw new TypeError("Failed to fetch");
    return { clips: [] } as T;
  });
  restores.push(() => requests.mockRestore());
  render(<PodcastClips episode={episode} />);
  fireEvent.click(screen.getByRole("button", { name: "Prepare Exports" }));
  await screen.findByText("Clip Action Failed. Please Retry.");
  fixture.refresh();
  await waitFor(() => expect(requests.mock.calls.length).toBeGreaterThanOrEqual(3));
  expect(screen.getByRole("alert").textContent).toBe("Clip Action Failed. Please Retry.");
});

it("removes loaded private draft rows immediately on account change", async () => {
  const fixture = clipFixture();
  const requests = spyOn(client, "podcastRequest").mockResolvedValue({ clips: [draft] });
  restores.push(() => requests.mockRestore());
  const view = render(<PodcastClips episode={episode} />);
  await screen.findByText(draft.title);
  fixture.authSpy.mockReturnValue({ session: { did: "did:bob" }, getOAuthSession: fixture.getOAuthSession } as ReturnType<typeof auth.useAuth>);
  view.rerender(<PodcastClips episode={episode} />);
  expect(screen.queryByText(draft.title)).toBeNull();
  expect(requests).toHaveBeenCalledTimes(1);
});

it("invalidates deferred polling synchronously across cross-tab A to B to A identity changes", async () => {
  clipFixture();
  let resolveOld: (result: { clips: client.PodcastClip[] }) => void = () => {};
  let oldSignal: AbortSignal | undefined;
  const requests = spyOn(client, "podcastRequest").mockImplementation(<T,>(_oauth: OAuthSession, _path: string, _method?: string, _body?: unknown, signal?: AbortSignal) => {
    if (!oldSignal) {
      oldSignal = signal;
      return new Promise<T>(resolve => { resolveOld = result => resolve(result as T); });
    }
    return Promise.resolve({ clips: [{ ...draft, id: "fresh", title: "Fresh Account Clip" }] } as T);
  });
  restores.push(() => requests.mockRestore());
  render(<PodcastClips episode={episode} />);
  await waitFor(() => expect(requests).toHaveBeenCalledTimes(1));
  fireEvent(window, new window.StorageEvent("storage", { key: "@@atproto/oauth-client-browser(sub)", newValue: "did:bob" }));
  expect(oldSignal?.aborted).toBe(true);
  fireEvent(window, new window.StorageEvent("storage", { key: "@@atproto/oauth-client-browser(sub)", newValue: "did:alice" }));
  await screen.findByText("Fresh Account Clip");
  resolveOld({ clips: [draft] });
  await waitFor(() => expect(screen.queryByText(draft.title)).toBeNull());
});
