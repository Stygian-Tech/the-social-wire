import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { act } from "react";
import { hydrateRoot } from "react-dom/client";
import { renderToString } from "react-dom/server";
import * as provider from "@/components/Podcasts/PodcastPlayerProvider";
import { SidebarAudioSection } from "@/components/AppSidebar/SidebarAudioSection";
import { SidebarProvider } from "@/components/ui/sidebar";
import { initialPodcastState } from "@/lib/podcasts/client";

const restores: (() => void)[] = [];
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); for (const restore of restores.splice(0).reverse()) restore(); });
function setup(playing = true, duration = 120, mount = true) {
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
  if (mount) render(<SidebarProvider><SidebarAudioSection enabled active={false} onSelect={() => calls.push("navigate")} /></SidebarProvider>);
  return calls;
}

function touch(target: HTMLElement, type: string, x = 20, y = 20) {
  const event = new window.MouseEvent(type, { bubbles: true, clientX: x, clientY: y });
  Object.defineProperty(event, "pointerType", { value: "touch" });
  Object.defineProperty(event, "pointerId", { value: 1 });
  fireEvent(target, event);
}
async function hold() { await act(async () => { await new Promise(resolve => setTimeout(resolve, 550)); }); }

describe("Podcast sidebar playback controls", () => {
  it("hydrates a plain sidebar tab even when cached playback restores before the sidebar, then enables its controls", async () => {
    const calls = setup(true, 120, false);
    const fixture = <SidebarProvider><SidebarAudioSection enabled active={false} onSelect={() => calls.push("navigate")} /></SidebarProvider>;
    const container = document.createElement("div");
    container.innerHTML = renderToString(fixture);
    document.body.append(container);
    expect(container.querySelector('[role="tab"]')).toBeTruthy();
    expect(container.querySelector('[data-base-ui-focus-guard]')).toBeNull();
    expect(container.querySelector('[role="tab"]')?.getAttribute("aria-describedby")).toBeNull();
    const errors: unknown[] = [];
    const error = spyOn(console, "error").mockImplementation((...args) => errors.push(args));
    restores.push(() => error.mockRestore());
    let root: ReturnType<typeof hydrateRoot> | undefined;
    try {
      await act(async () => {
        root = hydrateRoot(container, fixture, { onRecoverableError: (error) => errors.push(error) });
      });
      expect(errors).toEqual([]);
      expect(container.querySelector('[role="tab"]')?.getAttribute("aria-describedby")).toBeTruthy();
      fireEvent.focus(screen.getByRole("tab", { name: "Podcasts, Beta" }));
      await waitFor(() => expect(screen.getByRole("dialog", { name: "Podcast Mini Player" })).toBeTruthy());
      fireEvent.click(screen.getByRole("button", { name: "Pause Podcast" }));
      expect(calls).toEqual(["toggle"]);
      expect(errors).toEqual([]);
    } finally {
      await act(async () => { root?.unmount(); await new Promise(resolve => setTimeout(resolve, 0)); });
      container.remove();
    }
  });

  it("opens portal controls without navigating, toggles playback and seeks original audio", async () => {
    const calls = setup();
    expect(screen.queryByText("A Sidebar Episode")).toBeNull();
    const tab = screen.getByRole("tab", { name: "Podcasts, Beta" });
    expect(tab.children[0]?.tagName.toLowerCase()).toBe("svg");
    expect(tab.children[1]?.textContent).toBe("Podcasts");
    expect(tab.children[2]?.getAttribute("aria-hidden")).toBe("true");
    expect(tab.children[3]?.textContent).toBe("Beta");
    fireEvent.focus(screen.getByRole("tab", { name: "Podcasts, Beta" }));
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
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull());
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

  it("opens touch-and-hold controls and suppresses the release click without a separate button", async () => {
    const calls = setup();
    const tab = screen.getByRole("tab", { name: "Podcasts, Beta" });
    expect(screen.queryByRole("button", { name: "Podcast Playback Controls" })).toBeNull();
    touch(tab, "pointerdown");
    fireEvent.focus(tab);
    expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull();
    await hold();
    expect(screen.getByRole("dialog", { name: "Podcast Mini Player" })).toBeTruthy();
    touch(tab, "pointerup");
    fireEvent.click(tab);
    expect(calls).toEqual([]);
    expect(screen.getByRole("dialog", { name: "Podcast Mini Player" })).toBeTruthy();
  });

  it("navigates on a short touch tap without opening playback controls", async () => {
    const calls = setup();
    const tab = screen.getByRole("tab", { name: "Podcasts, Beta" });
    touch(tab, "pointerdown");
    fireEvent.focus(tab);
    touch(tab, "pointerup");
    fireEvent.click(tab);
    await hold();
    expect(calls).toEqual(["navigate"]);
    expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull();
  });

  it("cancels touch holds on movement and pointer cancellation without accidental navigation", async () => {
    const calls = setup();
    const tab = screen.getByRole("tab", { name: "Podcasts, Beta" });
    touch(tab, "pointerdown");
    touch(tab, "pointermove", 40, 20);
    await hold();
    touch(tab, "pointerup");
    fireEvent.click(tab);
    expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull();
    touch(tab, "pointerdown");
    touch(tab, "pointercancel");
    await hold();
    fireEvent.click(tab);
    expect(calls).toEqual([]);
    expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull();
  });

  it("clears a pending hold when the sidebar unmounts", async () => {
    setup();
    touch(screen.getByRole("tab", { name: "Podcasts, Beta" }), "pointerdown");
    cleanup();
    await hold();
    expect(screen.queryByRole("dialog", { name: "Podcast Mini Player" })).toBeNull();
  });

  it("disables seeking until duration is known and keeps playback available", async () => {
    setup(false, 0);
    fireEvent.focus(screen.getByRole("tab", { name: "Podcasts, Beta" }));
    await waitFor(() => expect(screen.getByRole("slider", { name: "Seek Podcast From Sidebar" })).toBeTruthy());
    expect((screen.getByRole("slider", { name: "Seek Podcast From Sidebar" }) as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Play Podcast" }) as HTMLButtonElement).disabled).toBe(false);
  });
});
