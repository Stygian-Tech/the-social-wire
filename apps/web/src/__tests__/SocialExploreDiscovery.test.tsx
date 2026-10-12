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
it("uses topic search and existing Open/Save feed actions", () => {
  const { mutate } = state(); let searched = "";
  render(<SocialExploreDiscovery moderation={moderation} savedFeeds={[]} enabled search={value => { searched = value; }} />);
  const topics = screen.getByRole("list", { name: "Trending Topics" });
  expect(within(topics).getAllByRole("listitem")).toHaveLength(1);
  fireEvent.click(within(topics).getByRole("button", { name: "Space News" }));
  expect(searched).toBe("space news");
  expect(screen.getByRole("link", { name: "Open Feed" }).getAttribute("href")).toBe(`/social?feed=${encodeURIComponent(feed.uri)}`);
  fireEvent.click(screen.getByRole("button", { name: "Save Feed" }));
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
  expect((screen.getByRole("button", { name: "Saved" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByRole("button", { name: "Save Feed" })).toBeNull();
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
