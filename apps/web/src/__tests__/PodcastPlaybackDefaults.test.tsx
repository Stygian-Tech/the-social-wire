import { afterEach, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { PodcastPlaybackDefaults } from "@/components/Podcasts/PodcastPlaybackDefaults";
import { initialPodcastState } from "@/lib/podcasts/client";
import type { PlayerContext } from "@/components/Podcasts/PodcastPlayerProvider";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); for (const restore of restores.splice(0).reverse()) restore(); });
function environment() {
  const values = { HTMLElement: window.HTMLElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout };
  for (const [name, value] of Object.entries(values)) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
  const changeState = mock(async () => {});
  const setRemoveSilences = mock(async () => {});
  const player: PlayerContext = { episode: null, playing: false, position: 0, duration: 0, state: initialPodcastState(), error: null, silence: null, play: async () => {}, toggle() {}, seek() {}, changeState, setRemoveSilences, clearError() {} };
  return { player, changeState, setRemoveSilences };
}

it("edits existing global preferences before playback and resets to 1x with silence removal off", async () => {
  const { player, changeState, setRemoveSilences } = environment();
  render(<PodcastPlaybackDefaults player={player} />);
  fireEvent.click(screen.getByRole("button", { name: "Playback Defaults" }));
  await waitFor(() => expect(screen.getByRole("dialog", { name: "Playback Defaults" })).toBeTruthy());
  expect((screen.getByRole("combobox", { name: "Default Speed" }) as HTMLSelectElement).value).toBe("1");
  expect((screen.getByRole("checkbox", { name: "Remove Silences by Default" }) as HTMLInputElement).checked).toBe(false);
  expect(screen.getAllByRole("option").map(option => (option as HTMLOptionElement).value)).toEqual(["0.75", "1", "1.25", "1.5", "1.75", "2"]);
  fireEvent.change(screen.getByRole("combobox", { name: "Default Speed" }), { target: { value: "1.5" } });
  expect(changeState).toHaveBeenCalledWith({ playbackSpeed: 1.5 });
  fireEvent.click(screen.getByRole("checkbox", { name: "Remove Silences by Default" }));
  expect(setRemoveSilences).toHaveBeenCalledWith(true);
  fireEvent.click(screen.getByRole("button", { name: "Reset Defaults" }));
  expect(changeState).toHaveBeenCalledWith({ playbackSpeed: 1, removeSilences: false });
});
