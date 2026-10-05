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
function analyserFixture(fail = false, empty = false, suspended = false, sampleRate = 48_000) {
  let tick = () => {};
  const timer = spyOn(globalThis, "setInterval").mockImplementation(((callback: () => void) => { tick = callback; return 123; }) as typeof setInterval);
  const clear = spyOn(globalThis, "clearInterval").mockImplementation(() => {});
  restores.push(() => timer.mockRestore(), () => clear.mockRestore());
  const stop = mock(() => {});
  let hasAudioTrack = !empty;
  const stream = Object.assign(new window.EventTarget(), { getTracks: () => [{ stop }], getAudioTracks: () => hasAudioTrack ? [{ stop }] : [] });
  const capture = mock(() => stream);
  const audio = document.createElement("audio");
  audio.src = "https://publisher.example/episode.mp3";
  Object.assign(audio, { captureStream: capture });
  const disconnect = mock(() => {});
  const connect = mock(() => {});
  const analyser = { fftSize: 0, frequencyBinCount: 2048, getByteFrequencyData: mock((data: Uint8Array) => { data.fill(0); data[3] = 255; data[9] = 128; }) };
  const close = mock(async () => {});
  let contextState = suspended ? "suspended" : "running";
  const resume = mock(async () => {});
  const createMediaElementSource = mock(() => { throw new Error("Must not reroute the original media"); });
  const createMediaStreamSource = mock(() => { if (fail) throw new Error("Capture unavailable"); return { disconnect, connect }; });
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "AudioContext");
  Object.defineProperty(globalThis, "AudioContext", { configurable: true, value: class {
    get state() { return contextState; }
    sampleRate = sampleRate;
    close = close; resume = resume; createMediaElementSource = createMediaElementSource;
    createMediaStreamSource = createMediaStreamSource;
    createAnalyser() { return analyser; }
  } });
  restores.push(() => { if (descriptor) Object.defineProperty(globalThis, "AudioContext", descriptor); else Reflect.deleteProperty(globalThis, "AudioContext"); });
  return { audio, capture, stream, stop, disconnect, connect, analyser, close, clear, resume, markRunning: () => { contextState = "running"; }, createMediaElementSource, createMediaStreamSource, tick: () => act(() => tick()), addTrack: () => act(() => { hasAudioTrack = true; stream.dispatchEvent(new window.Event("addtrack")); }) };
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
    expect(bars[0]?.className).not.toContain("podcast-waveform-indicator");
    fixture.analyser.getByteFrequencyData.mockImplementation(data => { data.fill(0); data[3] = 64; data[85] = 255; });
    fixture.tick();
    expect((bars[0] as HTMLElement).style.height).toBe("4px");
    expect((bars[2] as HTMLElement).style.height).toBe("16px");
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

  it.each([[100, 1], [4000, 3], [10000, 4]])("places %s Hz in logarithmic band %s", (frequency, band) => {
    const fixture = analyserFixture();
    fixture.analyser.getByteFrequencyData.mockImplementation(data => { data.fill(0); data[Math.round(frequency * 4096 / 48000)] = 255; });
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    fixture.tick();
    const bars = view.container.querySelectorAll("span > span");
    expect(fixture.analyser.fftSize).toBe(4096);
    for (let index = 0; index < bars.length; index++) {
      expect((bars[index] as HTMLElement).style.height).toBe(index === band ? "16px" : "1px");
    }
  });

  it("uses Nyquist as the upper frequency limit at lower sample rates", () => {
    const fixture = analyserFixture(false, false, false, 24_000);
    fixture.analyser.getByteFrequencyData.mockImplementation(data => { data.fill(0); data[2047] = 255; });
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    fixture.tick();
    const bars = view.container.querySelectorAll("span > span");
    expect((bars[4] as HTMLElement).style.height).toBe("16px");
    expect((bars[3] as HTMLElement).style.height).toBe("1px");
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
    expect(view.container.querySelector(".podcast-waveform-indicator")).toBeTruthy();
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
    expect(view.container.querySelector(".podcast-waveform-indicator")).toBeTruthy();
    expect(audio.muted).toBe(false);
    expect(audio.src).toBe("https://publisher.example/episode.mp3");
    view.rerender(<PodcastPlaybackWaveform player={player(audio, false)} />);
    expect(view.container.innerHTML).toBe("");
  });

  it("waits for delayed audio tracks and starts analysis when a track arrives", () => {
    const fixture = analyserFixture(false, true);
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    expect(view.container.querySelector(".podcast-waveform-indicator")).toBeTruthy();
    expect(fixture.stop).not.toHaveBeenCalled();
    expect(fixture.createMediaStreamSource).not.toHaveBeenCalled();
    fixture.addTrack();
    expect(fixture.createMediaStreamSource).toHaveBeenCalledWith(fixture.stream);
    fixture.tick();
    expect((view.container.querySelector("span > span") as HTMLElement).style.height).toBe("16px");
    expect(view.container.querySelector(".podcast-waveform-indicator")).toBeNull();
    expect(fixture.audio.muted).toBe(false);
    view.unmount();
    expect(fixture.stop).toHaveBeenCalledTimes(1);
  });

  it("removes waiting capture listeners on unmount and ignores later tracks", () => {
    const fixture = analyserFixture(false, true);
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    view.unmount();
    fixture.addTrack();
    firePlaying(fixture.audio);
    expect(fixture.createMediaStreamSource).not.toHaveBeenCalled();
    expect(fixture.stop).toHaveBeenCalledTimes(1);
  });

  it("resumes a suspended graph when user-initiated media playback starts", () => {
    const fixture = analyserFixture(false, false, true);
    const view = render(<PodcastPlaybackWaveform player={player(fixture.audio)} />);
    fixture.tick();
    expect(view.container.querySelector(".podcast-waveform-indicator")).toBeTruthy();
    expect(fixture.resume).toHaveBeenCalledTimes(1);
    firePlaying(fixture.audio);
    expect(fixture.resume).toHaveBeenCalledTimes(2);
    expect(fixture.createMediaStreamSource).toHaveBeenCalledTimes(1);
    expect(fixture.capture).toHaveBeenCalledTimes(1);
    fixture.markRunning();
    fixture.tick();
    expect(view.container.querySelector(".podcast-waveform-indicator")).toBeNull();
    expect((view.container.querySelector("span > span") as HTMLElement).style.height).toBe("16px");
  });
});

function firePlaying(audio: HTMLAudioElement) {
  act(() => audio.dispatchEvent(new window.Event("playing")));
}
