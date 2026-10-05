import { afterEach, describe, expect, it, spyOn } from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { act } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as gateway from "@/lib/socialWireGatewayClient";
import * as offline from "@/lib/podcasts/offline";
import {
  initialPodcastState,
  type PodcastEpisode,
} from "@/lib/podcasts/client";
import {
  PodcastPlayerProvider,
  usePodcastPlayer,
} from "@/components/Podcasts/PodcastPlayerProvider";
const episode: PodcastEpisode = {
  id: "episode",
  showId: "show",
  title: "An Episode",
  audioUrl: "https://publisher.test/audio.mp3",
  publishedAt: "2026-10-04T12:00:00Z",
  durationSeconds: 120,
  transcripts: [],
};
function Controls({ route, item = episode }: { route: string; item?: PodcastEpisode }) {
  const player = usePodcastPlayer();
  return (
    <div>
      <h1>{route}</h1>
      <button onClick={() => void player.play(item)}>Play Fixture</button>
      {player.error ? <p role="alert">{player.error}</p> : null}
      <span data-testid="progress">
        {player.state.progress.episode?.positionSeconds ?? 0}
      </span>
    </div>
  );
}
const restores: (() => void)[] = [];
afterEach(() => {
  cleanup();
  for (const restore of restores.splice(0).reverse()) restore();
  window.localStorage.clear();
});
function environment() {
  const storage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: window.localStorage,
  });
  restores.push(() => {
    if (storage) Object.defineProperty(globalThis, "localStorage", storage);
    else Reflect.deleteProperty(globalThis, "localStorage");
  });
  const flag = process.env.NEXT_PUBLIC_PODCASTS_ENABLED;
  process.env.NEXT_PUBLIC_PODCASTS_ENABLED = "true";
  restores.push(() => {
    if (flag === undefined) delete process.env.NEXT_PUBLIC_PODCASTS_ENABLED;
    else process.env.NEXT_PUBLIC_PODCASTS_ENABLED = flag;
  });
  let viewer: string | null = "did:plc:viewer-a";
  const oauth = {} as OAuthSession;
  const getOAuthSession = () => oauth;
  const hook = spyOn(auth, "useAuth").mockImplementation(
    () =>
      ({
        session: viewer ? { did: viewer } : null,
        getOAuthSession,
      }) as ReturnType<typeof auth.useAuth>,
  );
  restores.push(() => hook.mockRestore());
  const element = document.createElement("audio");
  let paused = true;
  Object.defineProperties(element, {
    duration: { configurable: true, get: () => 120 },
    paused: { configurable: true, get: () => paused },
  });
  element.load = () => {};
  element.play = async () => {
    paused = false;
    element.onloadedmetadata?.(new window.Event("loadedmetadata"));
    element.dispatchEvent(new window.Event("play"));
  };
  element.pause = () => {
    if (!paused) {
      paused = true;
      element.dispatchEvent(new window.Event("pause"));
    }
  };
  const oldAudio = Object.getOwnPropertyDescriptor(globalThis, "Audio");
  Object.defineProperty(globalThis, "Audio", {
    configurable: true,
    value: class {
      constructor() {
        return element;
      }
    },
  });
  restores.push(() => {
    if (oldAudio) Object.defineProperty(globalThis, "Audio", oldAudio);
    else Reflect.deleteProperty(globalThis, "Audio");
  });
  const get = spyOn(offline, "getPodcastDownload").mockResolvedValue(undefined);
  restores.push(() => get.mockRestore());
  const shell = spyOn(
    offline,
    "registerPodcastOfflineShell",
  ).mockResolvedValue();
  restores.push(() => shell.mockRestore());
  const requests: { path: string; body?: unknown }[] = [];
  const fetch = spyOn(gateway, "gatewayFetch").mockImplementation(
    async (_oauth, path, init) => {
      const body = init?.body ? JSON.parse(String(init.body)) : undefined;
      requests.push({ path, body });
      return Response.json({
        revision: 1,
        state: body?.state ?? initialPodcastState(),
      });
    },
  );
  restores.push(() => fetch.mockRestore());
  return {
    element,
    requests,
    getDownload: get,
    setViewer: (did: string | null) => {
      viewer = did;
    },
  };
}
describe("Persistent podcast player", () => {
  it("ignores no-source audio errors on initial mount and account reset but reports real playback errors", async () => {
    const env = environment();
    const view = render(<PodcastPlayerProvider><Controls route="Podcasts" /></PodcastPlayerProvider>);
    await act(async () => env.element.dispatchEvent(new window.Event("error")));
    expect(env.element.getAttribute("src")).toBeNull();
    expect(screen.queryByRole("alert")).toBeNull();
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play Fixture" })));
    await screen.findByRole("complementary", { name: "Podcast Player" });
    await act(async () => env.element.dispatchEvent(new window.Event("error")));
    expect(screen.getAllByRole("alert").some((alert) => alert.textContent?.includes("Audio could not load"))).toBe(true);
    env.setViewer("did:plc:viewer-b");
    view.rerender(<PodcastPlayerProvider><Controls route="Podcasts" /></PodcastPlayerProvider>);
    await act(async () => env.element.dispatchEvent(new window.Event("error")));
    expect(env.element.getAttribute("src")).toBeNull();
    expect(screen.queryByRole("alert")).toBeNull();
  });
  it("loads private audio with authenticated media fetch and disables public analysis", async () => {
    const env = environment();
    const fetch = spyOn(gateway, "gatewayFetch").mockImplementation(async (_oauth, path) => {
      if (path.startsWith("/v1/podcasts/media?")) return new Response(new Blob(["private audio"], { type: "audio/mpeg" }));
      return Response.json({ revision: 1, state: initialPodcastState() });
    });
    restores.push(() => fetch.mockRestore());
    const create = spyOn(URL, "createObjectURL").mockReturnValue("blob:private-audio");
    const revoke = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
    restores.push(() => create.mockRestore(), () => revoke.mockRestore());
    render(<PodcastPlayerProvider><Controls route="Podcasts" item={{ ...episode, visibility: "private", audioUrl: "/v1/podcasts/media?episodeId=episode" }} /></PodcastPlayerProvider>);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play Fixture" })));
    await waitFor(() => expect(env.element.src).toBe("blob:private-audio"));
    expect(fetch.mock.calls.some((call) => call[1] === "/v1/podcasts/media?episodeId=episode")).toBe(true);
    expect((screen.getByRole("checkbox", { name: "Remove Silences" }) as HTMLInputElement).disabled).toBe(true);
    expect(fetch.mock.calls.some((call) => call[1].includes("analysis"))).toBe(false);
  });
  it("keeps audio across route children, seeks and changes pitch-preserving speed", async () => {
    const env = environment();
    const view = render(
      <PodcastPlayerProvider>
        <Controls route="Podcasts" />
      </PodcastPlayerProvider>,
    );
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Play Fixture" }));
    });
    await screen.findByRole("complementary", { name: "Podcast Player" });
    expect(env.element.preservesPitch).toBe(true);
    fireEvent.change(screen.getByRole("combobox", { name: "Playback Speed" }), {
      target: { value: "3" },
    });
    await waitFor(() => expect(env.element.playbackRate).toBe(3));
    fireEvent.change(screen.getByRole("slider", { name: "Seek Podcast" }), {
      target: { value: "42" },
    });
    await waitFor(() => expect(env.element.currentTime).toBe(42));
    view.rerender(
      <PodcastPlayerProvider>
        <Controls route="Saved" />
      </PodcastPlayerProvider>,
    );
    expect(env.element.src).toBe(episode.audioUrl);
    expect(env.element.paused).toBe(false);
    await waitFor(() =>
      expect(
        env.requests.some(
          (request) =>
            request.body &&
            JSON.stringify(request.body).includes('"positionSeconds":42'),
        ),
      ).toBe(true),
    );
  });
  it("stops audio on viewer switch and does not write the old episode into the new viewer cache", async () => {
    const env = environment();
    const view = render(
      <PodcastPlayerProvider>
        <Controls route="Podcasts" />
      </PodcastPlayerProvider>,
    );
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Play Fixture" }));
    });
    await screen.findByRole("complementary", { name: "Podcast Player" });
    env.element.currentTime = 75;
    env.setViewer("did:plc:viewer-b");
    view.rerender(
      <PodcastPlayerProvider>
        <Controls route="Podcasts" />
      </PodcastPlayerProvider>,
    );
    await waitFor(() =>
      expect(
        screen.queryByRole("complementary", { name: "Podcast Player" }),
      ).toBeNull(),
    );
    expect(env.element.paused).toBe(true);
    const cache = JSON.parse(
      localStorage.getItem(
        "the-social-wire.podcast-state.v1:did:plc:viewer-b",
      ) ?? "{}",
    );
    expect(cache.state?.progress?.episode).toBeUndefined();
    expect(cache.episode).toBeNull();
  });
  it("restores only the stored viewer's local playback and downloads without OAuth requests when offline", async () => {
    const env = environment();
    env.setViewer(null);
    const online = Object.getOwnPropertyDescriptor(navigator, "onLine");
    Object.defineProperty(navigator, "onLine", {
      configurable: true,
      value: false,
    });
    restores.push(() => {
      if (online) Object.defineProperty(navigator, "onLine", online);
      else Reflect.deleteProperty(navigator, "onLine");
    });
    localStorage.setItem(
      "@@atproto/oauth-client-browser(sub)",
      "did:plc:offline",
    );
    localStorage.setItem(
      "the-social-wire.podcast-state.v1:did:plc:offline",
      JSON.stringify({
        state: {
          ...initialPodcastState(),
          progress: {
            episode: {
              positionSeconds: 53,
              updatedAt: "2026-10-05T01:00:00Z",
              completed: false,
            },
          },
        },
        pending: {},
      }),
    );
    env.getDownload.mockResolvedValue({
      episode,
      bytes: 3,
      downloadedAt: "2026-10-05T01:00:00Z",
      media: new Blob(["mp3"]),
    });
    render(
      <PodcastPlayerProvider>
        <Controls route="Podcasts" />
      </PodcastPlayerProvider>,
    );
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Play Fixture" }));
    });
    await screen.findByRole("complementary", { name: "Podcast Player" });
    expect(env.element.currentTime).toBe(53);
    expect(env.element.src.startsWith("blob:")).toBe(true);
    expect(env.requests).toHaveLength(0);
  });
});
