import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import * as Auth from "@/hooks/useAuth";
import * as Navigation from "next/navigation";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Notifications from "@/hooks/useSocialDiscovery";
import * as Actions from "@/components/Social/SocialPostActions";
import { SocialNotifications } from "@/components/Social/SocialNotifications";
import { SidebarProvider } from "@/components/ui/sidebar";
import { socialPostPageHref } from "@/lib/socialPostNavigation";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";

const did = "did:plc:alice";
const author = { did: "did:plc:bob", handle: "bob.test", displayName: "Bob" };
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const replyUri = `at://${author.did}/app.bsky.feed.post/reply`;
const parentUri = `at://${did}/app.bsky.feed.post/parent`;
const rootUri = `at://${did}/app.bsky.feed.post/root`;
const safety: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const replyRecord = { $type: "app.bsky.feed.post", text: "The actual nested reply", createdAt: "2026-10-10T00:00:00Z", reply: { parent: { uri: parentUri, cid }, root: { uri: rootUri, cid } } };
const notification = { uri: replyUri, cid, author, reason: "reply", reasonSubject: parentUri, record: replyRecord, isRead: false, indexedAt: "2026-10-10T00:00:00Z" };
const makePost = (uri: string, text: string): AppBskyFeedDefs.PostView => ({ uri, cid, author, record: { ...replyRecord, text }, indexedAt: notification.indexedAt });
const restores: (() => void)[] = [];
const push = mock((path: string) => { void path; });
const liked = mock((uri: string) => { void uri; });
let posts: AppBskyFeedDefs.PostView[];
let cache: QueryClient;
function restore(spy: { mockRestore(): void }) { restores.push(() => spy.mockRestore()); }
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={cache}><SidebarProvider>{children}</SidebarProvider></QueryClientProvider>; }
beforeEach(() => {
  push.mockClear(); liked.mockClear();
  cache = new QueryClient(); posts = [makePost(rootUri, "Thread root"), makePost(parentUri, "Immediate parent"), makePost(replyUri, replyRecord.text)];
  const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  restores.push(() => { if (media) Object.defineProperty(window, "matchMedia", media); else Reflect.deleteProperty(window, "matchMedia"); });
  restore(spyOn(Auth, "useAuth").mockReturnValue({ session: { did } } as unknown as ReturnType<typeof Auth.useAuth>));
  restore(spyOn(Navigation, "useRouter").mockReturnValue({ push, replace: push } as unknown as ReturnType<typeof Navigation.useRouter>));
  restore(spyOn(Navigation, "usePathname").mockReturnValue("/social/notifications"));
  restore(spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams() as ReturnType<typeof Navigation.useSearchParams>));
  restore(spyOn(Catalog, "useBlueskySocialCatalog").mockReturnValue({ data: { feeds: [], moderation: safety }, isError: false, isPending: false } as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>));
  restore(spyOn(Notifications, "useSocialNotifications").mockImplementation(() => ({ data: { pages: [{ notifications: [notification], posts }] }, isPending: false, isError: false }) as unknown as ReturnType<typeof Notifications.useSocialNotifications>));
  restore(spyOn(Notifications, "useSocialNotificationUnread").mockReturnValue({ data: 1 } as unknown as ReturnType<typeof Notifications.useSocialNotificationUnread>));
  restore(spyOn(Notifications, "useMarkSocialNotificationsSeen").mockReturnValue({ mutate: () => {}, isPending: false } as unknown as ReturnType<typeof Notifications.useMarkSocialNotificationsSeen>));
  restore(spyOn(Actions, "SocialPostActions").mockImplementation(({ post, onOpen }) => <><button onClick={onOpen}>Open {(post.record as { text: string }).text}</button><button onClick={() => liked(post.uri)}>Like {(post.record as { text: string }).text}</button></>));
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });

it("shows the reply and its immediate parent, with separate action targets and no thread root", async () => {
  render(<SocialNotifications />, { wrapper: Wrapper });
  expect(await screen.findByText(replyRecord.text)).toBeTruthy();
  expect(screen.getByText("Immediate parent")).toBeTruthy(); expect(screen.queryByText("Thread root")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Open The actual nested reply" }));
  expect(push).toHaveBeenCalledWith(socialPostPageHref(replyUri, "/social/notifications"));
  fireEvent.click(screen.getByRole("button", { name: "Like The actual nested reply" }));
  expect(liked).toHaveBeenCalledWith(replyUri);
  expect(liked).not.toHaveBeenCalledWith(parentUri); expect(liked).not.toHaveBeenCalledWith(rootUri);
  fireEvent.click(screen.getByRole("button", { name: "Open Immediate parent" }));
  expect(push).toHaveBeenLastCalledWith(socialPostPageHref(parentUri, "/social/notifications"));
  fireEvent.click(screen.getByRole("button", { name: "Like Immediate parent" }));
  expect(liked).toHaveBeenLastCalledWith(parentUri);
  expect(screen.getAllByRole("link", { name: "Bob" })[0]!.getAttribute("href")).toBe(socialProfilePageHref(author.did, "/social/notifications"));
});
it("a missing hydrated reply offers its own Open Post action and never falls back to either parent", async () => {
  posts = posts.filter(post => post.uri !== replyUri);
  render(<SocialNotifications />, { wrapper: Wrapper });
  expect(screen.queryByText("Immediate parent")).toBeNull(); expect(screen.queryByText("Thread root")).toBeNull();
  expect(screen.queryByRole("button", { name: "Like The actual nested reply" })).toBeNull();
  fireEvent.click(await screen.findByRole("button", { name: "Open Post" }));
  expect(push).toHaveBeenCalledWith(socialPostPageHref(replyUri, "/social/notifications"));
});


it("keeps the reply and its actions when the immediate parent is missing", async () => {
  posts = posts.filter(post => post.uri !== parentUri);
  render(<SocialNotifications />, { wrapper: Wrapper });
  expect(await screen.findByText(replyRecord.text)).toBeTruthy();
  expect(screen.getByText("Original post unavailable.")).toBeTruthy();
  expect(screen.queryByText("Thread root")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Like The actual nested reply" }));
  expect(liked).toHaveBeenCalledWith(replyUri);
});
it("withholds moderated parent content/actions without hiding the safe reply", async () => {
  posts = posts.map(post => post.uri === parentUri ? { ...post, author: { ...post.author, viewer: { blocking: `at://${did}/app.bsky.graph.block/one` } } } : post);
  render(<SocialNotifications />, { wrapper: Wrapper });
  expect(await screen.findByText(replyRecord.text)).toBeTruthy();
  expect(screen.getByText("Original post withheld by your moderation settings.")).toBeTruthy();
  expect(screen.queryByText("Immediate parent")).toBeNull();
  expect(screen.queryByRole("button", { name: "Like Immediate parent" })).toBeNull();
  expect(screen.getByRole("button", { name: "Like The actual nested reply" })).toBeTruthy();
});
