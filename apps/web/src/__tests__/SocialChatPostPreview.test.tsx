import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/blueskyPostClient";
import { SocialChatPostPreview } from "@/components/Social/SocialChatPostPreview";
import { SocialChatMessage } from "@/components/Social/SocialChatMessage";
import { socialPostPageHref } from "@/lib/socialPostNavigation";
const did = "did:plc:viewer";
const post = { uri: "at://did:plc:other/app.bsky.feed.post/one", cid: "bafyreia", author: { did: "did:plc:other", handle: "other.test" }, record: { $type: "app.bsky.feed.post", text: "Shared Post Body", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z" };
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
let client: QueryClient;
const push = mock(() => {});
const restores: (() => void)[] = [];
beforeEach(() => {
  push.mockClear();
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ push, replace: mock(() => {}) } as unknown as ReturnType<typeof Navigation.useRouter>);
  const path = spyOn(Navigation, "usePathname").mockReturnValue("/social/messages");
  const params = spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams() as ReturnType<typeof Navigation.useSearchParams>);
  restores.push(() => auth.mockRestore(), () => router.mockRestore(), () => path.mockRestore(), () => params.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
const url = "https://bsky.app/profile/did%3Aplc%3Aother/post/one";
describe("chat post previews", () => {
  it("hydrates canonical shared links through the viewer and opens body clicks internally", async () => {
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post } }); restores.push(() => fetch.mockRestore());
    render(<QueryClientProvider client={client}><SocialChatPostPreview text={url} moderation={moderation} /></QueryClientProvider>);
    fireEvent.click(await screen.findByText("Shared Post Body"));
    expect(fetch.mock.calls[0]![0]).toMatchObject({ uri: post.uri, moderation, session: { did } });
    expect(push).toHaveBeenCalledWith(socialPostPageHref(post.uri, "/social/messages"));
  });
  it("waits for moderation and withholds muted content without an open action", async () => {
    const fetch = spyOn(Client, "getBlueskyPostThread").mockResolvedValue({ thread: { $type: "app.bsky.feed.defs#threadViewPost", post: { ...post, author: { ...post.author, viewer: { muted: true } } } } }); restores.push(() => fetch.mockRestore());
    const view = render(<QueryClientProvider client={client}><SocialChatPostPreview text={url} /></QueryClientProvider>);
    expect(fetch).not.toHaveBeenCalled();
    view.rerender(<QueryClientProvider client={client}><SocialChatPostPreview text={url} moderation={moderation} /></QueryClientProvider>);
    await waitFor(() => expect(screen.getByText("Post preview withheld.")).toBeTruthy());
    expect(screen.queryByText("Shared Post Body") === null).toBe(true);
    expect(screen.queryByRole("link", { name: "Open Post" }) === null).toBe(true);
  });
  it("renders native record embeds safely and opens their own post without network hydration", () => {
    const fetch = spyOn(Client, "getBlueskyPostThread").mockRejectedValue(new Error("Must not hydrate native embed")); restores.push(() => fetch.mockRestore());
    const message = { $type: "chat.bsky.convo.defs#messageView" as const, id: "m", rev: "1", text: "Native share", sender: { did }, sentAt: post.indexedAt, embed: { $type: "app.bsky.embed.record#view" as const, record: { $type: "app.bsky.embed.record#viewRecord" as const, uri: post.uri, cid: post.cid, author: post.author, value: post.record, indexedAt: post.indexedAt } } };
    render(<SocialChatMessage message={message} viewerDid={did} moderation={moderation} pending={false} onDelete={() => {}} onReply={() => {}} onReaction={() => {}} />);
    fireEvent.click(screen.getByText("Shared Post Body"));
    expect(push).toHaveBeenCalledWith(socialPostPageHref(post.uri, "/social/messages"));
    expect(fetch).not.toHaveBeenCalled();
  });
});
