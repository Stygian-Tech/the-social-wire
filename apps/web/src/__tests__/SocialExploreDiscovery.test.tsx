import { afterEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { type AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import * as AvatarComponent from "@/components/shared/Avatar";
import * as Hook from "@/hooks/useSocialExploreDiscovery";
import { SocialExploreDiscovery } from "@/components/Social/SocialExploreDiscovery";
import { socialTrendingSearch } from "@/lib/socialExploreDiscoveryClient";

const moderation: ModerationOpts = { userDid: "did:plc:alice", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const feed: AppBskyFeedDefs.GeneratorView = { uri: "at://did:plc:other/app.bsky.feed.generator/news", cid: "bafyreia", did: "did:plc:service", creator: { did: "did:plc:other", handle: "other.test" }, displayName: "Science", indexedAt: "2026-10-10T00:00:00Z" };
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function state(overrides: Record<string, unknown> = {}) {
  const mutate = mock((uri: string) => { void uri; });
  const value: Record<string, unknown> = { topics: { data: { topics: [{ topic: "Space", displayName: "Space News", link: "https://bsky.app/search?q=space%20news" }], suggested: [] }, isPending: false, isError: false, refetch: () => {} }, feeds: { data: [feed], isPending: false, isError: false, refetch: () => {} }, save: { mutate, isPending: false, isError: false, reset: () => {} }, ...overrides };
  const hook = spyOn(Hook, "useSocialExploreDiscovery").mockReturnValue(value as unknown as ReturnType<typeof Hook.useSocialExploreDiscovery>);
  restores.push(() => hook.mockRestore());
  return { value, mutate };
}
it("uses topic search and existing Open/Add feed actions", () => {
  const { mutate } = state(); let searched = "";
  render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={value => { searched = value; }} />);
  const topics = screen.getByRole("list", { name: "Trending Topics" });
  expect(within(topics).getAllByRole("listitem")).toHaveLength(1);
  fireEvent.click(within(topics).getByRole("button", { name: "Space News" }));
  expect(searched).toBe("space news");
  expect(screen.getByRole("link", { name: "Open Feed" }).getAttribute("href")).toBe(`/social?feed=${encodeURIComponent(feed.uri)}`);
  fireEvent.click(screen.getByRole("button", { name: "Add Feed" }));
  expect(mutate).toHaveBeenCalledWith(feed.uri);
});
it("filters blocked feeds and gates metadata without moderation", () => {
  state({ feeds: { data: [{ ...feed, creator: { ...feed.creator, viewer: { blocking: "at://did:plc:alice/app.bsky.graph.block/one" } } }], isPending: false, isError: false } });
  const view = render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.queryByText("Science")).toBeNull();
  expect(screen.getByText("No recommended feeds to show right now.")).toBeTruthy();
  view.rerender(<SocialExploreDiscovery savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.getByText("Feed recommendations require your moderation settings.")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Space News" })).toBeTruthy();
});
it("keeps discovery sections independent on failure", () => {
  const { value } = state({ topics: { isPending: false, isError: true, error: new Error("Topic server unavailable"), refetch: () => {} } });
  const view = render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.getByRole("button", { name: "Retry Topics" })).toBeTruthy();
  expect(screen.getByText("Science")).toBeTruthy();
  value.topics = { data: { topics: [{ topic: "Space", link: "" }], suggested: [] }, isPending: false, isError: false };
  value.feeds = { isPending: false, isError: true, error: new Error("Feed server unavailable"), refetch: () => {} };
  view.rerender(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.getByRole("button", { name: "Space" })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Retry Feeds" })).toBeTruthy();
});
it("shows independent loading/empty states and hides discovery during search", () => {
  const { value } = state({ topics: { isPending: true }, feeds: { isPending: true } });
  const view = render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.getAllByRole("status")).toHaveLength(2);
  value.topics = { data: { topics: [], suggested: [] }, isPending: false, isError: false };
  value.feeds = { data: [], isPending: false, isError: false };
  view.rerender(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.getByText("No trending topics to show right now.")).toBeTruthy();
  expect(screen.getByText("No recommended feeds to show right now.")).toBeTruthy();
  view.rerender(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled={false} search={() => {}} />);
  expect(screen.queryByText("Trending Topics")).toBeNull();
});
it("falls back to text for untrusted topic links", () => {
  for (const link of ["javascript:alert(1)", "https://evil.test/search?q=secret", "https://bsky.app/profile/alice", "%%%"]) expect(socialTrendingSearch({ topic: "safe", link })).toBe("safe");
  expect(socialTrendingSearch({ topic: "fallback", link: "/search?q=%23science" })).toBe("#science");
});

it("saved feeds stay idempotent in discovery and offer the full feed directory", () => {
  state();
  render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[{ kind: "feed", uri: feed.uri, name: feed.displayName, pinned: false }]} enabled search={() => {}} />);
  expect((screen.getByRole("button", { name: "Added" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByRole("button", { name: "Add Feed" })).toBeNull();
  expect(screen.getByRole("link", { name: "Browse All Feeds" }).getAttribute("href")).toBe("/social/feeds");
});

it("shows sanitized recommendation avatars and withholds unsafe image sources", () => {
  const avatar = spyOn(AvatarComponent, "Avatar").mockImplementation(({ src }) => <span data-testid="feed-avatar" data-source={src ?? ""} />);
  restores.push(() => avatar.mockRestore());
  const { value } = state({ feeds: { data: [{ ...feed, avatar: "https://images.test/feed.png" }], isPending: false, isError: false } });
  const view = render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.getByTestId("feed-avatar").getAttribute("data-source")).toBe("https://images.test/feed.png");
  value.feeds = { data: [{ ...feed, avatar: "javascript:alert(1)" }], isPending: false, isError: false };
  view.rerender(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  expect(screen.getByTestId("feed-avatar").getAttribute("data-source")).toBe("");
});

it("shows descriptions for trending and suggested topics and keeps description clicks searchable", () => {
  state({ topics: { data: { topics: [{ topic: "Space", displayName: "Space News", description: "  A new mission launches.  ", link: "/search?q=space%20news" }], suggested: [{ topic: "Science", description: "<script>plain text</script>", link: "/search?q=science" }] }, isPending: false, isError: false } });
  const search = mock((query: string) => { void query; });
  render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={search} />);
  const topics = screen.getByRole("list", { name: "Trending Topics" });
  expect(topics.className).toContain("divide-y");
  expect(topics.className).toContain("divide-border");
  const description = within(topics).getByText("A new mission launches.");
  expect(description.closest("button")?.textContent).toContain("Space News");
  fireEvent.click(description);
  expect(search).toHaveBeenCalledWith("space news");
  expect(within(topics).getByText("<script>plain text</script>")).toBeTruthy();
  expect(topics.querySelector("script")).toBeNull();
});

it("keeps topics with absent, empty or whitespace-only descriptions title-only", () => {
  state({ topics: { data: { topics: [{ topic: "Space", link: "" }, { topic: "Science", description: "", link: "" }, { topic: "Nature", description: " \n ", link: "" }], suggested: [] }, isPending: false, isError: false } });
  render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  const topics = screen.getByRole("list", { name: "Trending Topics" });
  for (const title of ["Space", "Science", "Nature"]) {
    const button = within(topics).getByRole("button", { name: title });
    expect(button.textContent).toBe(title);
    expect(button.querySelectorAll("span")).toHaveLength(1);
  }
});


it("places trending topics and recommended feeds in separate cards", () => {
  state();
  render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={() => {}} />);
  const topics = screen.getByRole("region", { name: "Trending Topics" });
  const feeds = screen.getByRole("region", { name: "Recommended Feeds" });
  expect(topics).not.toBe(feeds);
  expect(topics.className).toContain("floating-glass");
  expect(feeds.className).toContain("floating-glass");
});
