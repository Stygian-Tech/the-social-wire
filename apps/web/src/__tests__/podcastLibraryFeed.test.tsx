import { afterEach, describe, expect, it } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { SidebarProvider } from "@/components/ui/sidebar";
import { SidebarAudioSection } from "@/components/AppSidebar/SidebarAudioSection";
import { PublicationTabs } from "@/components/AppSidebar/PublicationTabs";
import { SidebarTopicsSection } from "@/components/AppSidebar/SidebarTopicsSection";
import { PodcastLibrarySidebar } from "@/components/Podcasts/PodcastLibrarySidebar";
import { podcastFeedEpisodes } from "@/lib/podcasts/library";
import type { PodcastEpisode } from "@/lib/podcasts/client";
const episode = (id: string): PodcastEpisode => ({ id, showId: "show", title: id, publishedAt: "2026-10-05", audioUrl: "/audio", transcripts: [] });
afterEach(cleanup);
describe("Podcast library feed selection", () => {
  it("places Podcasts in Audio even when article feeds and Topics are hidden", () => {
    const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
    Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
    const calls: string[] = [];
    const { container } = render(<SidebarProvider><SidebarAudioSection enabled active onSelect={() => calls.push("podcasts")} /><PublicationTabs visibleFeeds={new Set()} activeTab={null} onTabChange={() => {}} /><SidebarTopicsSection visibleFeeds={new Set()} /></SidebarProvider>);
    expect(screen.getByText("Audio")).toBeTruthy();
    expect(screen.queryByText("Feeds")).toBeNull();
    expect(screen.queryByText("Topics")).toBeNull();
    expect(container.querySelector('[aria-label="Audio"]')?.contains(screen.getByRole("tab", { name: "Podcasts" }))).toBe(true);
    fireEvent.click(screen.getByRole("tab", { name: "Podcasts" }));
    expect(calls).toEqual(["podcasts"]);
    cleanup();
    if (media) Object.defineProperty(window, "matchMedia", media);
    else Reflect.deleteProperty(window, "matchMedia");
  });
  it("keeps queue order and resolves offline episodes without displaying unrelated episodes", () => {
    expect(podcastFeedEpisodes("queue", [episode("b"), episode("unrelated")], [episode("a")], ["a", "b", "missing"]).map(item => item.id)).toEqual(["a", "b"]);
    expect(podcastFeedEpisodes("downloads", [episode("online")], [episode("offline")], []).map(item => item.id)).toEqual(["offline"]);
  });
  it("changes center feed selections and lists only subscribed shows", () => {
    const calls: unknown[] = [];
    render(<PodcastLibrarySidebar feed="recent" showId={null} downloadCount={2} queueCount={1} subscriptions={["owned"]} shows={[
      { id: "owned", title: "My Show", sourceKind: "private-rss", visibility: "private" },
      { id: "discovered", title: "Unsubscribed Show", sourceKind: "rss" },
    ]} onSelect={(...args) => calls.push(args)} />);
    expect(screen.getByRole("button", { name: "Recently Added" }).getAttribute("aria-current")).toBe("page");
    fireEvent.click(screen.getByRole("button", { name: /Downloaded/ }));
    fireEvent.click(screen.getByRole("button", { name: /Up Next/ }));
    fireEvent.click(screen.getByRole("button", { name: /My Show/ }));
    expect(calls).toEqual([["downloads"], ["queue"], ["show", "owned"]]);
    expect(screen.queryByText("Unsubscribed Show")).toBeNull();
    expect(screen.getByText("Private Feed")).toBeTruthy();
  });
});
