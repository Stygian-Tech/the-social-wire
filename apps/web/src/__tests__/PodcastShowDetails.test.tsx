import { afterEach, beforeEach, expect, it } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { act } from "react";
import { PodcastShowDetails } from "@/components/Podcasts/PodcastShowDetails";
import type { PodcastShow } from "@/lib/podcasts/client";

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
const show: PodcastShow = { id: "show", title: "A Show", sourceKind: "rss", description: "<p>First &amp; Full Paragraph.</p><p>Second Paragraph.<br>Next Line.</p><script>alert('bad')</script>" };

it("keeps a three-line summary and opens the full safe paragraph text in a scrollable dialog", async () => {
  const { container } = render(<PodcastShowDetails show={show} action={<button>Subscribe</button>} />);
  const description = "First & Full Paragraph.\n\nSecond Paragraph.\nNext Line.";
  const summary = container.querySelector("p")!;
  expect(summary.className).toContain("line-clamp-3");
  expect(summary.textContent).toBe(description);
  expect(screen.queryByRole("dialog")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Show More" }));
  const dialog = await screen.findByRole("dialog", { name: "About A Show" });
  const full = within(dialog).getByLabelText("Full Podcast Description");
  expect(full.textContent).toBe(description);
  expect(full.className).toContain("overflow-y-auto");
  expect(full.className).toContain("whitespace-pre-wrap");
  expect(full.querySelector("script")).toBeNull();
  expect(full.querySelector("p")).toBeNull();
  expect(dialog.className).toContain("max-h-[calc(100svh-2rem)]");
  fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(screen.getByRole("button", { name: "Subscribe" })).toBeTruthy();
});

it("resets the description dialog across show navigation and preserves plain-text paragraphs", async () => {
  const view = render(<PodcastShowDetails show={show} />);
  fireEvent.click(screen.getByRole("button", { name: "Show More" }));
  await screen.findByRole("dialog", { name: "About A Show" });
  const other = { ...show, id: "other", title: "Other Show", description: "Plain paragraph.\n\nAnother paragraph." };
  view.rerender(<PodcastShowDetails show={other} />);
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  fireEvent.click(screen.getByRole("button", { name: "Show More" }));
  const dialog = await screen.findByRole("dialog", { name: "About Other Show" });
  expect(within(dialog).getByLabelText("Full Podcast Description").textContent).toBe(other.description);
  view.rerender(<PodcastShowDetails show={show} />);
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});

it("omits Show More when the show has no readable description", () => {
  const view = render(<PodcastShowDetails show={{ ...show, description: undefined }} />);
  expect(screen.queryByRole("button", { name: "Show More" })).toBeNull();
  view.rerender(<PodcastShowDetails show={{ ...show, description: "<p> </p>" }} />);
  expect(screen.queryByRole("button", { name: "Show More" })).toBeNull();
});
