import { afterEach, expect, spyOn, test } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import * as Playback from "@/components/Podcasts/PodcastPlayerProvider";
import * as Auth from "@/hooks/useAuth";
import { PodcastContentPane } from "@/components/Podcasts/PodcastContentPane";
import { initialPodcastState } from "@/lib/podcasts/client";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); for (const restore of restores.splice(0).reverse()) restore(); });

test("Podcasts keeps scrolling content and the full player inside the same bounded pane", () => {
  for (const name of ["HTMLElement", "Element", "Node", "MutationObserver", "DOMRect"] as const) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value: window[name] });
    restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
  const authHook = spyOn(Auth, "useAuth").mockReturnValue({
    session: null, getOAuthSession: () => undefined,
  } as unknown as ReturnType<typeof Auth.useAuth>);
  const hook = spyOn(Playback, "usePodcastPlayer").mockReturnValue({
    episode: { id: "episode", showId: "show", title: "An Episode", audioUrl: "https://example.test/audio.mp3", publishedAt: "2026-10-05", transcripts: [] },
    playing: false, position: 0, duration: 120, state: initialPodcastState(), error: null, silence: null,
    play: async () => {}, toggle() {}, seek() {}, changeState: async () => {}, setRemoveSilences: async () => {}, clearError() {},
  } as Playback.PlayerContext);
  try {
    render(<PodcastContentPane><button>Last Episode</button></PodcastContentPane>);
    const content = screen.getByRole("main");
    const player = screen.getByRole("complementary", { name: "Podcast Player" });
    expect(content.classList.contains("overflow-y-auto")).toBe(true);
    expect(content.classList.contains("min-h-0")).toBe(true);
    expect(content.parentElement).toBe(player.parentElement);
    expect(player.previousElementSibling).toBe(content);
    expect(player.classList.contains("shrink-0")).toBe(true);
    expect(player.classList.contains("fixed")).toBe(false);
    expect(content.parentElement?.classList.contains("overflow-hidden")).toBe(true);
  } finally { hook.mockRestore(); authHook.mockRestore(); }
});
