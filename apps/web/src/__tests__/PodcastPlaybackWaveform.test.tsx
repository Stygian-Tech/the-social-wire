import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import { PodcastPlaybackWaveform } from "@/components/Podcasts/PodcastPlaybackWaveform";
import type { PlayerContext } from "@/components/Podcasts/PodcastPlayerProvider";
import { initialPodcastState } from "@/lib/podcasts/client";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); for (const restore of restores.splice(0).reverse()) restore(); });
function player(audio: HTMLAudioElement, playing = true): PlayerContext {
  return { episode: null, playing, position: 0, duration: 100, state: initialPodcastState(), error: null, silence: null,
    play: async () => {}, toggle() {}, seek() {}, changeState: async () => {}, setRemoveSilences: async () => {}, clearError() {}, getAudioElement: () => audio };
}
function analyserFixture(fail = false, empty = false) {
  let tick = () => {};
  const timer = spyOn(globalThis, "setInterval").mockImplementation(((callback: () => void) => { tick = callback; return 123; }) as typeof setInterval);
  const clear = spyOn(globalThis, "clearInterval").mockImplementation(() => {});
  restores.push(() => timer.mockRestore(), () => clear.mockRestore());
  const stop = mock(() => {});
  const stream = { getTracks: () => [{ stop }], getAudioTracks: () => empty ? [] : [{ stop }] };
  const capture = mock(() => stream);
  const audio = document.createElement("audio");
  audio.src = "https://publisher.example/episode.mp3";
  Object.assign(audio, { captureStream: capture });
  const disconnect = mock(() => {});
  const connect = mock(() => {});
  const analyser = { fftSize: 0, frequencyBinCount: 128, getByteFrequencyData: mock((data: Uint8Array) => { data.fill(0); data[1] = 255; data[9] = 128; }) };
  const close = mock(async () => {});
  const resume = mock(async () => {});
  const createMediaElementSource = mock(() => { throw new Error("Must not reroute the original media"); });
  const createMediaStreamSource = mock(() => { if (fail) throw new Error("Capture unavailable"); return { disconnect, connect }; });
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "AudioContext");
  Object.defineProperty(globalThis, "AudioContext", { configurable: true, value: class {
    state = "running";
    close = close; resume = resume; createMediaElementSource = createMediaElementSource;
    createMediaStreamSource = createMediaStreamSource;
    createAnalyser() { return analyser; }
  } });
  restores.push(() => { if (descriptor) Object.defineProperty(globalThis, "AudioContext", descriptor); else Reflect.deleteProperty(globalThis, "AudioContext"); });
  return { audio, capture, stream, stop, disconnect, connect, analyser, close, clear, createMediaElementSource, createMediaStreamSource, tick: () => act(() => tick()) };
}

describe("Podcast reactive waveform", () => {
  it("uses captured frequency bands and releases only the captured stream when paused", () => {
    const fixture = analyserFixture();
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    expect(fixture.capture).toHaveBeenCalledTimes(1);
    expect(fixture.createMediaStreamSource).toHaveBeenCalledWith(fixture.stream);
    expect(fixture.connect).toHaveBeenCalledWith(fixture.analyser);
    fixture.tick();
    const bars = view.container.querySelectorAll("span > span");
    expect((bars[0] as HTMLElement).style.height).toBe("16px");
    expect((bars[1] as HTMLElement).style.height).toBe("8px");
    expect((bars[2] as HTMLElement).style.height).toBe("1px");
    expect(bars[0]?.className).not.toContain("animate-pulse");
    view.rerender(<PodcastPlaybackWaveform player={player(fixture.audio, false)} />);
    expect(view.container.innerHTML).toBe("");
    expect(fixture.clear).toHaveBeenCalledWith(123);
    expect(fixture.disconnect).toHaveBeenCalledTimes(1);
    expect(fixture.stop).toHaveBeenCalledTimes(1);
    expect(fixture.close).toHaveBeenCalledTimes(1);
    expect(fixture.createMediaElementSource).not.toHaveBeenCalled();
    expect(fixture.audio.muted).toBe(false);
    expect(fixture.audio.src).toBe("https://publisher.example/episode.mp3");
  });

  it("releases analysis on unmount", () => {
    const fixture = analyserFixture();
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    view.unmount();
    expect(fixture.stop).toHaveBeenCalledTimes(1);
    expect(fixture.disconnect).toHaveBeenCalledTimes(1);
    expect(fixture.close).toHaveBeenCalledTimes(1);
  });

  it("keeps the audio graph stable across playback progress updates", () => {
    const fixture = analyserFixture();
    const state = player(fixture.audio);
    const view = render(<PodcastPlaybackWaveform player={state} />);
    view.rerender(<PodcastPlaybackWaveform player={{ ...state, position: 20 }} />);
    expect(fixture.capture).toHaveBeenCalledTimes(1);
    expect(fixture.disconnect).not.toHaveBeenCalled();
    fixture.tick();
    expect((view.container.querySelector("span > span") as HTMLElement).style.height).toBe("16px");
  });

  it("falls back safely when stream analysis fails without muting the original audio", () => {
    const fixture = analyserFixture(true);
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    expect(view.container.querySelector(".animate-pulse")).toBeTruthy();
    expect(fixture.stop).toHaveBeenCalledTimes(1);
    expect(fixture.close).toHaveBeenCalledTimes(1);
    expect(fixture.createMediaElementSource).not.toHaveBeenCalled();
    expect(fixture.audio.muted).toBe(false);
    expect(fixture.audio.src).toBe("https://publisher.example/episode.mp3");
    view.unmount();
    expect(fixture.close).toHaveBeenCalledTimes(1);
  });

  it("shows a harmless fallback without capture support and nothing while paused", () => {
    const audio = document.createElement("audio");
    audio.src = "https://publisher.example/episode.mp3";
    const view = render(<PodcastPlaybackWaveform player={player(audio)} />);
    expect(view.container.querySelector(".animate-pulse")).toBeTruthy();
    expect(audio.muted).toBe(false);
    expect(audio.src).toBe("https://publisher.example/episode.mp3");
    view.rerender(<PodcastPlaybackWaveform player={player(audio, false)} />);
    expect(view.container.innerHTML).toBe("");
  });

  it("releases empty capture streams without creating an audio graph", () => {
    const fixture = analyserFixture(false, true);
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    expect(view.container.querySelector(".animate-pulse")).toBeTruthy();
    expect(fixture.stop).toHaveBeenCalledTimes(1);
    expect(fixture.createMediaStreamSource).not.toHaveBeenCalled();
    expect(fixture.audio.muted).toBe(false);
  });
});
