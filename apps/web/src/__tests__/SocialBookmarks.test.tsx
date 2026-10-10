import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Client from "@/lib/blueskyBookmarksClient";
import { SidebarProvider } from "@/components/ui/sidebar";
import { SocialBookmarks } from "@/components/Social/SocialBookmarks";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const post = { $type: "app.bsky.feed.defs#postView" as const, uri: "at://did:plc:other/app.bsky.feed.post/test", cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text: "My Saved Social Post", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z" };
const restores: (() => void)[] = [];
let queryClient: QueryClient;
beforeEach(() => {
 const desc = Object.getOwnPropertyDescriptor(window, "matchMedia");
 Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
 restores.push(() => { if (desc) Object.defineProperty(window, "matchMedia", desc); else Reflect.deleteProperty(window, "matchMedia"); });
 queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
 const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }) as unknown as OAuthSession, oauthSessionReloadSeq: 0, signIn: async () => {} } as unknown as ReturnType<typeof Auth.useAuth>);
 const catalog = spyOn(Catalog, "useBlueskySocialCatalog").mockReturnValue({ data: { moderation }, isPending: false, isError: false } as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>);
 restores.push(() => auth.mockRestore(), () => catalog.mockRestore());
});
afterEach(() => { cleanup(); queryClient.clear(); restores.splice(0).reverse().forEach(fn => fn()); });
async function show() { await act(async () => { render(<QueryClientProvider client={queryClient}><SidebarProvider><SocialBookmarks /></SidebarProvider></QueryClientProvider>); }); }
describe("Social Bookmarks Workspace", () => {
 it("renders bookmarked posts and removes them only after a successful server write", async () => {
  const read = spyOn(Client, "getBlueskyBookmarks").mockResolvedValue({ bookmarks: [{ subject: { uri: post.uri, cid: post.cid }, item: post }] });
  const write = spyOn(Client, "setBlueskyBookmark").mockResolvedValue();
  restores.push(() => read.mockRestore(), () => write.mockRestore());
  await show();
  await waitFor(() => expect(screen.getByText("My Saved Social Post")).toBeTruthy());
  read.mockResolvedValue({ bookmarks: [] });
  fireEvent.click(screen.getByRole("button", { name: "Remove Bookmark" }));
  await waitFor(() => expect(screen.getByText(/No bookmarks yet/)).toBeTruthy());
  expect(write.mock.calls[0][0]).toMatchObject({ uri: post.uri, saved: false, session: { did } });
 });
 it("keeps a bookmark selected when the server rejects removal", async () => {
  const read = spyOn(Client, "getBlueskyBookmarks").mockResolvedValue({ bookmarks: [{ subject: { uri: post.uri, cid: post.cid }, item: post }] });
  const write = spyOn(Client, "setBlueskyBookmark").mockRejectedValue(new Error(SCOPE_RECOVERY_MESSAGE));
  restores.push(() => read.mockRestore(), () => write.mockRestore());
  await show();
  await waitFor(() => expect(screen.getByText("My Saved Social Post")).toBeTruthy());
  fireEvent.click(screen.getByRole("button", { name: "Remove Bookmark" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "Log In Again" })).toBeTruthy());
  expect(screen.getByRole("button", { name: "Remove Bookmark" }).getAttribute("aria-pressed")).toBe("true");
  expect(read).toHaveBeenCalledTimes(1);
 });
 it("shows blocked/missing bookmarks safely and stops pagination on a repeated cursor", async () => {
  const read = spyOn(Client, "getBlueskyBookmarks").mockResolvedValue({ bookmarks: [{ subject: { uri: post.uri, cid: post.cid }, item: { $type: "app.bsky.feed.defs#blockedPost", uri: post.uri, blocked: true } }], cursor: "same" });
  restores.push(() => read.mockRestore());
  await show();
  await waitFor(() => expect(screen.getByText("Bookmarked post unavailable.")).toBeTruthy());
  expect(screen.queryByText("My Saved Social Post")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Load More" }));
  await waitFor(() => expect(screen.queryByRole("button", { name: "Load More" })).toBeNull());
  expect(screen.getAllByText("Bookmarked post unavailable.")).toHaveLength(1);
 });
 it("offers permission renewal rather than presenting failed private reads as an empty list", async () => {
  const read = spyOn(Client, "getBlueskyBookmarks").mockRejectedValue(new Error(SCOPE_RECOVERY_MESSAGE));
  restores.push(() => read.mockRestore());
  await show();
  await waitFor(() => expect(screen.getByRole("button", { name: "Log In Again" })).toBeTruthy());
  expect(screen.queryByText(/No bookmarks yet/)).toBeNull();
 });
});
