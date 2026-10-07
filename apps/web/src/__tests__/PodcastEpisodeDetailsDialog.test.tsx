import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { act } from "react";
import { PodcastEpisodeDetailsDialog } from "@/components/Podcasts/PodcastEpisodeDetailsDialog";
import type { PodcastEpisode } from "@/lib/podcasts/client";
import * as nextImage from "next/image";
import type { ImageProps } from "next/image";

const restores: (() => void)[] = [];
beforeEach(() => {
  const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, MutationObserver: window.MutationObserver, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout };
  for (const [name, value] of Object.entries(values)) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); restores.splice(0).reverse().forEach(restore => restore()); });
const episode: PodcastEpisode = { id: "episode", showId: "show", title: "The Episode", audioUrl: "/audio", publishedAt: "2026-10-05", transcripts: [], description: '<p>Full &amp; Formatted Notes.</p><ul><li>A Topic</li></ul><a href="https://example.com/notes">Source</a><script>alert("bad")</script><img src="https://example.com/image.jpg" onerror="alert(1)">' };

it("opens complete sanitized show notes from the episode body and closes without playback", async () => {
  const view = render(<PodcastEpisodeDetailsDialog episode={episode} showName="Primary Technology" />);
  const trigger = screen.getByRole("button", { name: "Show Notes: The Episode" });
  expect(trigger.tagName).toBe("BUTTON");
  expect(trigger.firstElementChild?.textContent).toBe("Primary Technology");
  expect(screen.queryByRole("dialog")).toBeNull();
  fireEvent.click(trigger);
  const dialog = await screen.findByRole("dialog", { name: episode.title });
  expect(within(dialog).getByText("Primary Technology · Show Notes")).toBeTruthy();
  const notes = within(dialog).getByLabelText("Episode Show Notes");
  expect(notes.querySelector("p")?.textContent).toBe("Full & Formatted Notes.");
  expect(notes.querySelector("li")?.textContent).toBe("A Topic");
  expect(notes.querySelector("script")).toBeNull();
  expect(notes.querySelector("img")?.getAttribute("onerror")).toBeNull();
  const link = within(notes).getByRole("link", { name: "Source" });
  expect(link.getAttribute("href")).toBe("https://example.com/notes");
  expect(link.getAttribute("target")).toBe("_blank");
  expect(notes.className).toContain("overflow-y-auto");
  fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  view.rerender(<PodcastEpisodeDetailsDialog episode={{ ...episode, description: "Updated Notes" }} showName="Primary Technology" />);
  fireEvent.click(screen.getByRole("button", { name: "Show Notes: The Episode" }));
  expect(within(await screen.findByRole("dialog")).getByLabelText("Episode Show Notes").textContent).toBe("Updated Notes");
});

it("offers a clear empty state when an episode has no notes or known podcast name", async () => {
  render(<PodcastEpisodeDetailsDialog episode={{ ...episode, description: undefined }} />);
  fireEvent.click(screen.getByRole("button", { name: "Show Notes: The Episode" }));
  const dialog = await screen.findByRole("dialog", { name: episode.title });
  expect(within(dialog).getByText("Episode Show Notes")).toBeTruthy();
  expect(within(dialog).getByText("No Show Notes Are Available for This Episode")).toBeTruthy();
});

it("shows bounded episode artwork in the notes header and falls back to show artwork", async () => {
  const imageSpy = spyOn(nextImage, "default").mockImplementation((({ src, alt, width, height, style, onError, className }: ImageProps) =>
    // eslint-disable-next-line @next/next/no-img-element
    <img src={typeof src === "string" ? src : ""} alt={alt} width={width} height={height} style={style} onError={onError} className={className} />) as unknown as typeof nextImage.default);
  restores.push(() => imageSpy.mockRestore());
  const withArtwork = { ...episode, artworkUrl: "https://publisher.test/episode.jpg", showArtworkUrl: "https://publisher.test/show.jpg" };
  render(<PodcastEpisodeDetailsDialog episode={withArtwork} showName="Primary Technology" />);
  fireEvent.click(screen.getByRole("button", { name: "Show Notes: The Episode" }));
  const dialog = await screen.findByRole("dialog", { name: episode.title });
  const image = within(dialog).getByRole("img", { name: "The Episode Artwork" }) as HTMLImageElement;
  expect(image.src).toBe(withArtwork.artworkUrl);
  expect(image.style.width).toBe("64px");
  expect(image.style.height).toBe("64px");
  expect(image.className).toContain("object-cover");
  fireEvent.error(image);
  expect(image.src).toBe(withArtwork.showArtworkUrl);
  expect(image.style.width).toBe("64px");
  expect(image.style.height).toBe("64px");
});
