import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type Hls from "hls.js";
import * as Playback from "@/lib/socialVideoPlayback";
import { SocialVideoPlayer } from "@/components/Social/SocialVideoPlayer";

const src = "https://video.example/playlist.m3u8";
const video = { $type: "app.bsky.embed.video#view" as const, cid: "bafyreia", playlist: src, alt: "Fixture Video", aspectRatio: { width: 640, height: 360 } };
const realLoader = Playback.loadSocialVideoHls;
const restores: (() => void)[] = [];
const engines: FakeHls[] = [];
class FakeHls {
  static supported = true;
  static Events = { ERROR: "error" };
  static isSupported() { return this.supported; }
  error?: (event: string, data: { fatal: boolean }) => void;
  loadSource = mock((url: string) => { void url; });
  attachMedia = mock((element: HTMLMediaElement) => { void element; });
  destroy = mock(() => {});
  constructor() { engines.push(this); }
  on(_event: string, callback: (event: string, data: { fatal: boolean }) => void) { this.error = callback; }
}
beforeEach(() => {
  engines.length = 0; FakeHls.supported = true;
  const load = spyOn(Playback, "loadSocialVideoHls").mockResolvedValue(FakeHls as unknown as typeof Hls);
  const reset = spyOn(window.HTMLMediaElement.prototype, "load").mockImplementation(() => {});
  const native = spyOn(window.HTMLMediaElement.prototype, "canPlayType").mockReturnValue("");
  restores.push(() => load.mockRestore(), () => reset.mockRestore(), () => native.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(fn => fn()); });

describe("Social video playback", () => {
  it("loads the real streaming module on demand", async () => {
    const engine = await realLoader();
    expect(typeof engine.isSupported).toBe("function");
    expect(String(engine.Events.ERROR)).toBe("hlsError");
  });
  it("waits until the video enters the viewport before loading HLS", async () => {
    let intersect!: IntersectionObserverCallback;
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, "IntersectionObserver");
    const disconnect = mock(() => {});
    class Observer {
      constructor(callback: IntersectionObserverCallback) { intersect = callback; }
      observe = mock(() => {});
      disconnect = disconnect;
    }
    Object.defineProperty(globalThis, "IntersectionObserver", { configurable: true, value: Observer });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, "IntersectionObserver", descriptor); else Reflect.deleteProperty(globalThis, "IntersectionObserver"); });
    render(<SocialVideoPlayer video={video} src={src} />);
    expect(Playback.loadSocialVideoHls).not.toHaveBeenCalled();
    await act(async () => intersect([{ isIntersecting: true } as IntersectionObserverEntry], {} as IntersectionObserver));
    await waitFor(() => expect(engines).toHaveLength(1));
    expect(disconnect).toHaveBeenCalled();
  });
  it("shows a recoverable message when neither native nor MSE playback is supported", async () => {
    FakeHls.supported = false;
    render(<SocialVideoPlayer video={video} src={src} />);
    expect(await screen.findByRole("button", { name: "Retry Video" })).toBeTruthy();
    expect(engines).toHaveLength(0);
  });
  it("attaches an HLS engine and cleans it up on unmount", async () => {
    const view = render(<SocialVideoPlayer video={video} src={src} />);
    await waitFor(() => expect(engines[0]?.attachMedia).toHaveBeenCalledWith(screen.getByLabelText("Fixture Video")));
    expect(engines[0]!.loadSource).toHaveBeenCalledWith(src);
    view.unmount(); expect(engines[0]!.destroy).toHaveBeenCalledTimes(1);
  });
  it("prefers the HLS engine even when a browser claims native support", async () => {
    window.HTMLMediaElement.prototype.canPlayType = () => "maybe";
    render(<SocialVideoPlayer video={video} src={src} />);
    await waitFor(() => expect(engines).toHaveLength(1));
    expect(screen.getByLabelText("Fixture Video").getAttribute("src")).toBeNull();
  });
  it("uses native HLS when media source playback is unavailable", async () => {
    FakeHls.supported = false;
    window.HTMLMediaElement.prototype.canPlayType = () => "probably";
    render(<SocialVideoPlayer video={video} src={src} />);
    await waitFor(() => expect(screen.getByLabelText("Fixture Video").getAttribute("src")).toBe(src));
    expect(engines).toHaveLength(0);
  });
  it("plays direct media without loading the streaming engine", () => {
    const file = "https://video.example/fixture.mp4";
    render(<SocialVideoPlayer video={video} src={file} />);
    expect(screen.getByLabelText("Fixture Video").getAttribute("src")).toBe(file);
    expect(Playback.loadSocialVideoHls).not.toHaveBeenCalled();
  });
  it("shows unsupported playback and retries after a load failure", async () => {
    const load = spyOn(Playback, "loadSocialVideoHls").mockRejectedValueOnce(new Error("chunk failed")).mockResolvedValue(FakeHls as unknown as typeof Hls);
    restores.push(() => load.mockRestore());
    render(<SocialVideoPlayer video={video} src={src} />);
    expect(await screen.findByText("Video Could Not Be Loaded.")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Retry Video" }));
    await waitFor(() => expect(engines).toHaveLength(1));
    expect(screen.queryByText("Video Could Not Be Loaded.")).toBeNull();
  });
  it("destroys a fatal stream and recreates it on explicit retry", async () => {
    render(<SocialVideoPlayer video={video} src={src} />);
    await waitFor(() => expect(engines).toHaveLength(1));
    await act(async () => engines[0]!.error?.("error", { fatal: true }));
    fireEvent.click(await screen.findByRole("button", { name: "Retry Video" }));
    await waitFor(() => expect(engines).toHaveLength(2));
    expect(engines[0]!.destroy).toHaveBeenCalledTimes(1);
  });
  it("does not attach media after unmount while the engine is loading", async () => {
    let finish!: (value: typeof Hls) => void;
    const load = spyOn(Playback, "loadSocialVideoHls").mockReturnValue(new Promise(resolve => { finish = resolve; }));
    restores.push(() => load.mockRestore());
    const view = render(<SocialVideoPlayer video={video} src={src} />);
    view.unmount(); finish(FakeHls as unknown as typeof Hls);
    await Promise.resolve(); await Promise.resolve();
    expect(engines).toHaveLength(0);
  });
});
