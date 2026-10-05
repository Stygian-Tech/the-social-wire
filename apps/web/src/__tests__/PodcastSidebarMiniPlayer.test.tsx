import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { act } from "react";
import * as provider from "@/components/Podcasts/PodcastPlayerProvider";
import { SidebarAudioSection } from "@/components/AppSidebar/SidebarAudioSection";
import { SidebarProvider } from "@/components/ui/sidebar";
import { initialPodcastState } from "@/lib/podcasts/client";

const restores: (() => void)[] = [];
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); for (const restore of restores.splice(0).reverse()) restore(); });
function setup(playing = true, duration = 120) {
  const actEnvironment = Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT");
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", { configurable: true, value: true });
  restores.push(() => { if (actEnvironment) Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", actEnvironment); else Reflect.deleteProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT"); });
  for (const name of ["HTMLElement", "Element", "Node", "MutationObserver", "DOMRect", "getComputedStyle"] as const) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name);
    const value = name === "getComputedStyle" ? window.getComputedStyle.bind(window) : window[name];
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
  for (const [name, value] of Object.entries({ requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
  const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  restores.push(() => { if (media) Object.defineProperty(window, "matchMedia", media); else Reflect.deleteProperty(window, "matchMedia"); });
  const calls: (number | string)[] = [];
  const player: provider.PlayerContext = {
    episode: { id: "episode", showId: "show", title: "A Sidebar Episode", publishedAt: "2026-10-05", audioUrl: "/audio", transcripts: [], chapters: [{ startSeconds: 0, title: "Opening Chapter" }] },
    playing, position: 30, duration, state: initialPodcastState(), error: null, silence: null,
    play: async () => {}, toggle: () => calls.push("toggle"), seek: value => calls.push(value), changeState: async () => {}, setRemoveSilences: async () => {}, clearError() {},
  };
  const hook = spyOn(provider, "useOptionalPodcastPlayer").mockReturnValue(player);
  restores.push(() => hook.mockRestore());
  render(<SidebarProvider><SidebarAudioSection enabled active={false} onSelect={() => calls.push("navigate")} /></SidebarProvider>);
  return calls;
}

describe("Podcast sidebar playback controls", () => {
  it("opens portal controls without navigating, toggles playback and seeks original audio", async () => {
    const calls = setup();
    expect(screen.queryByText("A Sidebar Episode")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Podcast Playback Controls" }));
    await waitFor(() => expect(screen.getByRole("dialog", { name: "Podcast Mini Player" })).toBeTruthy());
    expect(screen.getByText("A Sidebar Episode")).toBeTruthy();
    expect(screen.getByText("Opening Chapter")).toBeTruthy();
    expect(screen.getByRole("img", { name: "Episode Artwork: A Sidebar Episode" })).toBeTruthy();
    expect(screen.getByText("0:30")).toBeTruthy();
    expect(screen.getByText("2:00")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Pause Podcast" }));
    fireEvent.change(screen.getByRole("slider", { name: "Seek Podcast From Sidebar" }), { target: { value: "75" } });
    expect(calls).toEqual(["toggle", 75]);
    fireEvent.click(screen.getByRole("button", { name: "Close Podcast Controls" }));
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull());
  });

  it("supports keyboard focus preview while retaining Podcasts navigation and Beta", async () => {
    const calls = setup(false);
    const tab = screen.getByRole("tab", { name: "Podcasts, Beta" });
    expect(screen.getByText("Beta")).toBeTruthy();
    fireEvent.focus(tab);
    await waitFor(() => expect(screen.getByRole("button", { name: "Play Podcast" })).toBeTruthy());
    fireEvent.click(tab);
    expect(calls).toEqual(["navigate"]);
  });

  it("opens from the Podcasts tab hover and keeps controls available across the pointer gap", async () => {
    setup();
    const tab = screen.getByRole("tab", { name: "Podcasts, Beta" });
    const pointer = new window.MouseEvent("pointerover", { bubbles: true });
    Object.defineProperty(pointer, "pointerType", { value: "mouse" });
    fireEvent(tab, pointer);
    fireEvent.mouseEnter(tab);
    fireEvent.mouseMove(tab);
    await waitFor(() => expect(screen.getByRole("dialog", { name: "Podcast Mini Player" })).toBeTruthy());
    const popup = screen.getByRole("dialog", { name: "Podcast Mini Player" });
    fireEvent.mouseLeave(tab);
    fireEvent.mouseEnter(popup.parentElement!);
    fireEvent.mouseEnter(popup);
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 250)); });
    expect(screen.getByRole("dialog", { name: "Podcast Mini Player" })).toBeTruthy();
    fireEvent.keyDown(popup, { key: "Escape", code: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull());
  });

  it("disables seeking until duration is known and keeps playback available", async () => {
    setup(false, 0);
    fireEvent.click(screen.getByRole("button", { name: "Podcast Playback Controls" }));
    await waitFor(() => expect(screen.getByRole("slider", { name: "Seek Podcast From Sidebar" })).toBeTruthy());
    expect((screen.getByRole("slider", { name: "Seek Podcast From Sidebar" }) as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Play Podcast" }) as HTMLButtonElement).disabled).toBe(false);
  });
});
