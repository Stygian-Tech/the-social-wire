import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Navigation from "next/navigation";
import type { ModerationOpts } from "@atproto/api";
import * as Auth from "@/hooks/useAuth";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Discovery from "@/hooks/useSocialDiscovery";
import * as Header from "@/components/FeedHeader/FeedHeader";
import * as Recommendations from "@/components/Social/SocialExploreDiscovery";
import * as Posts from "@/components/Social/InteractiveSocialPost";
import * as People from "@/components/Social/SocialExplorePersonCard";
import { SocialExplore } from "@/components/Social/SocialExplore";

const moderation: ModerationOpts = { userDid: "did:plc:alice", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const actor = { did: "did:plc:other", handle: "other.test" };
const post = { uri: "at://did:plc:other/app.bsky.feed.post/one", cid: "cid", author: actor, record: { $type: "app.bsky.feed.post", text: "A matching post", createdAt: "2026-10-22T00:00:00Z" }, indexedAt: "2026-10-22T00:00:00Z" };
function result() {
  return { data: { pages: [{ actors: [actor], posts: [post] }] }, isPending: false, isError: false, error: undefined as unknown, hasNextPage: true, isFetchingNextPage: false, isFetchNextPageError: false, fetchNextPage: mock(async () => {}), refetch: mock(async () => {}) };
}
let people: ReturnType<typeof result>;
let posts: ReturnType<typeof result>;
let params: URLSearchParams;
let catalog: Record<string, unknown>;
let cache: QueryClient;
const replace = mock(() => {});
const restores: (() => void)[] = [];
const calls: unknown[][] = [];
beforeEach(() => {
  people = result(); posts = result(); params = new URLSearchParams("q=trees&type=posts"); replace.mockClear(); calls.length = 0;
  catalog = { data: { moderation, feeds: [] }, isError: false, refetch: mock(async () => ({ isError: false })) };
  cache = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } });
  const spies = [
    spyOn(Navigation, "useSearchParams").mockImplementation(() => params as ReturnType<typeof Navigation.useSearchParams>),
    spyOn(Navigation, "useRouter").mockReturnValue({ replace } as unknown as ReturnType<typeof Navigation.useRouter>),
    spyOn(Auth, "useAuth").mockReturnValue({ session: { did: moderation.userDid } } as ReturnType<typeof Auth.useAuth>),
    spyOn(Catalog, "useBlueskySocialCatalog").mockImplementation(() => catalog as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>),
    spyOn(Header, "FeedHeader").mockImplementation(() => <header>Explore</header>),
    spyOn(Recommendations, "SocialExploreDiscovery").mockImplementation(({ enabled }) => enabled ? <div>Discovery</div> : null),
    spyOn(Posts, "InteractiveSocialPost").mockImplementation(() => <div>A matching post</div>),
    spyOn(People, "SocialExplorePersonCard").mockImplementation(({ actor }) => <div>{actor.handle}</div>),
    spyOn(Discovery, "useSocialExplore").mockImplementation((query, kind, settings) => { calls.push([query, kind, settings]); return (kind === "posts" ? posts : people) as unknown as ReturnType<typeof Discovery.useSocialExplore>; }),
  ];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function content() { return <QueryClientProvider client={cache}><SocialExplore /></QueryClientProvider>; }

it("submits one query for both types and removes the legacy type parameter", () => {
  render(content());
  expect(screen.queryByRole("group", { name: "Search Type" })).toBeNull();
  expect(screen.getByText("other.test")).toBeTruthy();
  expect(screen.getByText("A matching post")).toBeTruthy();
  fireEvent.change(screen.getByRole("textbox", { name: "Search Bluesky" }), { target: { value: "  oceans  " } });
  fireEvent.click(screen.getByRole("button", { name: "Search" }));
  expect(calls).toContainEqual(["oceans", "people", moderation]);
  expect(calls).toContainEqual(["oceans", "posts", moderation]);
  expect(replace).toHaveBeenCalledWith("/social/explore?q=oceans", { scroll: false });
});
it("keeps blank search suggestions without enabling duplicate empty post requests", () => {
  params = new URLSearchParams(); render(content());
  expect(screen.getByRole("region", { name: "Suggested People" })).toBeTruthy();
  expect(screen.queryByRole("region", { name: "Posts" })).toBeNull();
  expect(screen.getByText("Discovery")).toBeTruthy();
  expect(calls).toContainEqual(["", "posts", undefined]);
  expect(calls).toContainEqual(["", "people", moderation]);
});
it("keeps people visible while posts load or fail, with independent retry", () => {
  posts.isPending = true; const ui = render(content());
  expect(screen.getByText("other.test")).toBeTruthy();
  posts.isPending = false; posts.isError = true; posts.error = new Error("Post search failed"); posts.data.pages = [];
  ui.rerender(content());
  expect(screen.getByText("other.test")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Retry Posts" }));
  expect(posts.refetch).toHaveBeenCalledTimes(1); expect(people.refetch).not.toHaveBeenCalled();
});
it("paginates independently", () => {
  render(content());
  fireEvent.click(screen.getByRole("button", { name: "Load More Posts" }));
  expect(posts.fetchNextPage).toHaveBeenCalledTimes(1); expect(people.fetchNextPage).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Load More People" }));
  expect(people.fetchNextPage).toHaveBeenCalledTimes(1);
});
it("retains both results during a people pagination error and retries that page", () => {
  people.isError = true; people.isFetchNextPageError = true; people.error = new Error("More people failed"); render(content());
  expect(screen.getByText("other.test")).toBeTruthy(); expect(screen.getByText("A matching post")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Retry People" }));
  expect(people.fetchNextPage).toHaveBeenCalledTimes(1); expect(people.refetch).not.toHaveBeenCalled();
});
it("deduplicates and filters moderated people and posts", () => {
  people.data.pages[0].actors = [actor, actor, { ...actor, did: "did:plc:blocked", handle: "blocked.test", viewer: { blocking: "at://did:plc:alice/app.bsky.graph.block/one" } } as typeof actor];
  posts.data.pages[0].posts = [post, post, { ...post, uri: `${post.uri}blocked`, author: { ...actor, viewer: { blocking: "at://did:plc:alice/app.bsky.graph.block/one" } } } as typeof post];
  render(content());
  expect(screen.getAllByText("other.test")).toHaveLength(1); expect(screen.queryByText("blocked.test")).toBeNull();
  expect(screen.getAllByText("A matching post")).toHaveLength(1);
});
it("withholds both cached result sets when moderation belongs to another viewer or fails", () => {
  catalog.data = { moderation: { ...moderation, userDid: "did:plc:previous" }, feeds: [] };
  const ui = render(content());
  expect(screen.queryByText("other.test")).toBeNull(); expect(screen.queryByText("A matching post")).toBeNull();
  catalog.isError = true; catalog.error = new Error("Moderation unavailable"); ui.rerender(content());
  expect(screen.getByRole("alert")).toBeTruthy();
  expect(screen.queryByText("other.test")).toBeNull(); expect(screen.queryByText("A matching post")).toBeNull();
});
