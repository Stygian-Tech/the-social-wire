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
import * as client from "@/lib/podcasts/client";
import { PodcastPlayerView } from "@/components/Podcasts/PodcastPlayerView";
import {
  initialPodcastState,
  type PodcastEpisode,
} from "@/lib/podcasts/client";
import {
  PodcastPlayerProvider,
  usePodcastPlayer,
  type PlayerContext,
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
  const online = Object.getOwnPropertyDescriptor(navigator, "onLine");
  Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
  restores.push(() => { if (online) Object.defineProperty(navigator, "onLine", online); else Reflect.deleteProperty(navigator, "onLine"); });
  const actEnvironment = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { configurable: true, value: true });
  restores.push(() => { if (actEnvironment) Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", actEnvironment); else Reflect.deleteProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT"); });
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
  it("seeks chapter markers, previews artwork, and restores a minimized player without interrupting audio", async () => {
    const env = environment();
    const chaptered = { ...episode, artworkUrl: "https://publisher.test/episode.jpg", showArtworkUrl: "https://publisher.test/show.jpg", chapters: [{ startSeconds: 0, title: "Introduction" }, { startSeconds: 60, title: "Main Topic", artworkUrl: "https://publisher.test/chapter.jpg" }] };
    render(<PodcastPlayerProvider><Controls route="Podcasts" item={chaptered} /></PodcastPlayerProvider>);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play Fixture" })));
    const marker = await screen.findByRole("button", { name: "Seek to Chapter: Main Topic, 1:00" });
    fireEvent.focus(marker);
    expect(screen.getByRole("tooltip").textContent).toContain("Main Topic");
    fireEvent.click(marker);
    await waitFor(() => expect(env.element.currentTime).toBe(60));
    expect(screen.getAllByRole("img", { name: "Chapter Artwork: Main Topic" }).length).toBeGreaterThan(0);
    fireEvent.click(screen.getByRole("button", { name: "Minimize Player" }));
    expect(screen.queryByRole("slider", { name: "Seek Podcast" })).toBeNull();
    expect(env.element.paused).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Show Podcast Controls" }));
    expect(screen.getByRole("button", { name: "Pause" })).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Restore Player" }));
    expect(screen.getByRole("slider", { name: "Seek Podcast" })).toBeDefined();
    expect(env.element.currentTime).toBe(60);
  });
  it("reserves measured player space from an empty state through expanded and minimized layouts", async () => {
    environment();
    let height = 300;
    let resize: (() => void) | undefined;
    let disconnected = false;
    const observer = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
    Object.defineProperty(globalThis, "ResizeObserver", { configurable: true, value: class {
      constructor(callback: () => void) { resize = callback; }
      observe() {}
      disconnect() { disconnected = true; }
    } });
    restores.push(() => { if (observer) Object.defineProperty(globalThis, "ResizeObserver", observer); else Reflect.deleteProperty(globalThis, "ResizeObserver"); });
    const rect = spyOn(window.HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      const measured = this.getAttribute("aria-label") === "Podcast Player" ? (this.classList.contains("group") ? 80 : height) : 0;
      const gap = this.classList.contains("group") ? 76 : 64;
      return { x: 0, y: window.innerHeight - measured - gap, width: 384, height: measured, top: window.innerHeight - measured - gap, bottom: window.innerHeight - gap, left: 0, right: 384, toJSON() {} };
    });
    restores.push(() => rect.mockRestore());
    const empty: PlayerContext = { episode: null, playing: false, position: 0, duration: 0, state: initialPodcastState(), error: null, silence: null, play: async () => {}, toggle() {}, seek() {}, changeState: async () => {}, setRemoveSilences: async () => {}, clearError() {} };
    const view = render(<PodcastPlayerView player={empty} />);
    expect(document.documentElement.style.getPropertyValue("--podcast-player-height")).toBe("");
    view.rerender(<PodcastPlayerView player={{ ...empty, episode }} />);
    await screen.findByRole("complementary", { name: "Podcast Player" });
    expect(document.documentElement.style.getPropertyValue("--podcast-player-height")).toBe("364px");
    height = 450;
    await act(async () => resize?.());
    expect(document.documentElement.style.getPropertyValue("--podcast-player-height")).toBe("514px");
    fireEvent.click(screen.getByRole("button", { name: "Minimize Player" }));
    expect(document.documentElement.style.getPropertyValue("--podcast-player-height")).toBe("156px");
    expect(disconnected).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Restore Player" }));
    expect(document.documentElement.style.getPropertyValue("--podcast-player-height")).toBe("514px");
    view.unmount();
    resize?.();
    expect(document.documentElement.style.getPropertyValue("--podcast-player-height")).toBe("");
  });
  it("keeps arbitrary scrubbing available when chapter marks are dense", async () => {
    const env = environment();
    const chaptered = { ...episode, chapters: Array.from({ length: 120 }, (_, startSeconds) => ({ startSeconds, title: `Chapter ${startSeconds}` })) };
    render(<PodcastPlayerProvider><Controls route="Podcasts" item={chaptered} /></PodcastPlayerProvider>);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play Fixture" })));
    const slider = await screen.findByRole("slider", { name: "Seek Podcast" });
    fireEvent.change(slider, { target: { value: "37.5" } });
    await waitFor(() => expect(env.element.currentTime).toBe(37.5));
    fireEvent.click(screen.getByRole("button", { name: "Seek to Chapter: Chapter 95, 1:35" }));
    await waitFor(() => expect(env.element.currentTime).toBe(95));
    fireEvent.change(slider, { target: { value: "40.5" } });
    await waitFor(() => expect(env.element.currentTime).toBe(40.5));
  });
  it("normalizes a legacy offline playback preference before playing", async () => {
    const env = environment();
    const online = Object.getOwnPropertyDescriptor(navigator, "onLine");
    Object.defineProperty(navigator, "onLine", { configurable: true, value: false });
    restores.push(() => { if (online) Object.defineProperty(navigator, "onLine", online); else Reflect.deleteProperty(navigator, "onLine"); });
    localStorage.setItem("the-social-wire.podcast-state.v1:did:plc:viewer-a", JSON.stringify({ state: { ...initialPodcastState(), playbackSpeed: 3 }, pending: { playbackSpeed: 3 } }));
    env.getDownload.mockResolvedValue({ episode, bytes: 3, downloadedAt: "2026-10-05", media: new Blob(["mp3"]) });
    render(<PodcastPlayerProvider><Controls route="Podcasts" /></PodcastPlayerProvider>);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play Fixture" })));
    await waitFor(() => expect(env.element.playbackRate).toBe(2));
    expect((screen.getByRole("combobox", { name: "Playback Speed" }) as HTMLSelectElement).value).toBe("2");
    expect(screen.getAllByRole("option").map((option) => option.textContent)).toEqual(["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"]);
  });
  it.each([undefined, "v1"])("does not skip old downloaded silence metadata offline (%s)", async (analysisVersion) => {
    const env = environment();
    const online = Object.getOwnPropertyDescriptor(navigator, "onLine");
    Object.defineProperty(navigator, "onLine", { configurable: true, value: false });
    restores.push(() => { if (online) Object.defineProperty(navigator, "onLine", online); else Reflect.deleteProperty(navigator, "onLine"); });
    localStorage.setItem("the-social-wire.podcast-state.v1:did:plc:viewer-a", JSON.stringify({ state: { ...initialPodcastState(), removeSilences: true } }));
    env.getDownload.mockResolvedValue({ episode, bytes: 3, downloadedAt: "2026-10-05", media: new Blob(["mp3"]), silence: { status: "complete", intervals: [{ start: 5, end: 12 }], analysisVersion } });
    render(<PodcastPlayerProvider><Controls route="Podcasts" /></PodcastPlayerProvider>);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play Fixture" })));
    await screen.findByRole("complementary", { name: "Podcast Player" });
    await act(async () => { env.element.currentTime = 6; env.element.dispatchEvent(new window.Event("timeupdate")); });
    expect(env.element.currentTime).toBe(6);
    expect(env.element.paused).toBe(false);
    expect(env.requests).toHaveLength(0);
  });
  it("refreshes legacy cached analysis online and applies only v2 original-time intervals", async () => {
    const env = environment();
    localStorage.setItem("the-social-wire.podcast-state.v1:did:plc:viewer-a", JSON.stringify({ state: { ...initialPodcastState(), removeSilences: true } }));
    env.getDownload.mockResolvedValue({ episode, bytes: 3, downloadedAt: "2026-10-05", media: new Blob(["mp3"]), silence: { status: "complete", intervals: [{ start: 5, end: 12 }], analysisVersion: "v1" } });
    const save = spyOn(offline, "savePodcastDownload").mockResolvedValue();
    restores.push(() => save.mockRestore());
    const paths: { path: string; method?: string }[] = [];
    const request = spyOn(client, "podcastRequest").mockImplementation(async <T,>(_oauth: OAuthSession, path: string, method?: string, body?: unknown): Promise<T> => {
      paths.push({ path, method });
      if (path.startsWith("analysis")) return { status: "complete", analysisVersion: "v2", intervals: [{ start: 10, end: 20 }] } as T;
      return { revision: 1, state: body ? (body as { state: client.PodcastState }).state : { ...initialPodcastState(), removeSilences: true } } as T;
    });
    restores.push(() => request.mockRestore());
    render(<PodcastPlayerProvider><Controls route="Podcasts" /></PodcastPlayerProvider>);
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Play Fixture" })));
    await screen.findByRole("complementary", { name: "Podcast Player" });
    await waitFor(() => expect(paths.some((call) => call.path === "analysis" && call.method === "POST")).toBe(true));
    await act(async () => { env.element.currentTime = 6; env.element.dispatchEvent(new window.Event("timeupdate")); });
    expect(env.element.currentTime).toBe(6);
    await act(async () => { env.element.currentTime = 15; env.element.dispatchEvent(new window.Event("timeupdate")); });
    expect(env.element.currentTime).toBe(20);
    expect(save.mock.calls.some((call) => call[0] === "did:plc:viewer-a" && call[1].silence?.analysisVersion === "v2")).toBe(true);
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
      target: { value: "2" },
    });
    await waitFor(() => expect(env.element.playbackRate).toBe(2));
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
