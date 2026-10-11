import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Network from "@/lib/atprotoNetwork";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Chat from "@/lib/blueskyChatClient";
import { SidebarProvider } from "@/components/ui/sidebar";
import { SocialMessages } from "@/components/Social/SocialMessages";
const alice = "did:plc:abcdefghijklmnopqrstuvwx";
const bob = "did:plc:zzzzzzzzzzzzzzzzzzzzzzzz";
const convo = { id: "c", rev: "1", members: [{ did: alice, handle: "alice.test" }, { did: bob, handle: "bob.test" }], unreadCount: 1, muted: false };
let viewer: string;
let oauth: string;
let client: QueryClient;
let params: URLSearchParams;
const restores: (() => void)[] = [];
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => { Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }); });
afterAll(() => { if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia); else Reflect.deleteProperty(window, "matchMedia"); });
beforeEach(() => {
  viewer = alice; oauth = alice;
  for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
  }
  const catalog = spyOn(Catalog, "useBlueskySocialCatalog").mockReturnValue({ data: { moderation: { userDid: alice, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } } }, isError: false } as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>); restores.push(() => catalog.mockRestore());
  params = new URLSearchParams();
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ push: mock(() => {}), replace: mock(() => {}) } as unknown as ReturnType<typeof Navigation.useRouter>);
  const path = spyOn(Navigation, "usePathname").mockReturnValue("/social/messages");
  restores.push(() => router.mockRestore(), () => path.mockRestore());
  const search = spyOn(Navigation, "useSearchParams").mockImplementation(() => params as ReturnType<typeof Navigation.useSearchParams>); restores.push(() => search.mockRestore());
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession: () => ({ did: oauth } as OAuthSession), oauthSessionReloadSeq: 0 } as ReturnType<typeof Auth.useAuth>)); restores.push(() => auth.mockRestore());
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://appview.test", plcDirectory: "https://plc.test", handleResolver: "https://appview.test", appViewDid: "did:web:appview.test", chatServiceDid: "did:web:chat.test" }); restores.push(() => network.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).forEach(restore => restore()); });
async function mount() { await act(async () => { render(<QueryClientProvider client={client}><SidebarProvider><SocialMessages /></SidebarProvider></QueryClientProvider>); }); }
describe("Messages workspace", () => {
  it("shows the local service limitation without requesting chats", async () => {
    const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://appview.test", plcDirectory: "https://plc.test", handleResolver: "https://appview.test", appViewDid: "did:web:appview.test" }); restores.push(() => network.mockRestore());
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [] }); restores.push(() => list.mockRestore());
    await mount();
    expect(screen.getByText("Messages Unavailable Locally")).toBeTruthy();
    expect(list).not.toHaveBeenCalled();
  });
  it("opens actual conversations, sends, marks read, mutes, and confirms delete-for-self", async () => {
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [convo] }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [{ $type: "chat.bsky.convo.defs#messageView", id: "m", rev: "2", text: "Received Message", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" }] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /bob.test/ }));
    expect(await screen.findByText("Received Message")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Outgoing" } });
    fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
    await waitFor(() => expect(write.mock.calls[0]![2]).toEqual({ kind: "send", convoId: "c", text: "Outgoing" }));
    await waitFor(() => expect((screen.getByLabelText("Message") as HTMLTextAreaElement).value).toBe(""));
    fireEvent.click(screen.getByRole("button", { name: "Mark As Read" }));
    await waitFor(() => expect(write.mock.calls.some(call => call[2].kind === "read")).toBe(true));
    fireEvent.click(screen.getByRole("button", { name: "Mute" }));
    await waitFor(() => expect(write.mock.calls.some(call => call[2].kind === "mute")).toBe(true));
    fireEvent.click(screen.getByRole("button", { name: "Message Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Delete For Me" }));
    expect(write.mock.calls.some(call => call[2].kind === "delete")).toBe(false);
    fireEvent.click(screen.getAllByRole("button", { name: "Delete For Me" }).at(-1)!);
    await waitFor(() => expect(write.mock.calls.some(call => call[2].kind === "delete" && call[2].messageId === "m")).toBe(true));
  });
  it("fails closed if the OAuth identity differs from the displayed account", async () => {
    oauth = bob;
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [convo] }); restores.push(() => list.mockRestore());
    await mount();
    expect(await screen.findByText("Your account changed. Please reload Messages.")).toBeTruthy();
    expect(list).not.toHaveBeenCalled();
  });
  it("retains a shared post draft through existing and new recipient selection and sends only explicitly", async () => {
    const draft = `https://bsky.app/profile/${encodeURIComponent(bob)}/post/shared`;
    params.set("draft", draft);
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [convo] }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
    await mount();
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(await screen.findByRole("button", { name: /bob.test/ }));
    expect((screen.getByLabelText("Message") as HTMLTextAreaElement).value).toBe(draft);
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "New Conversation" }));
    await screen.findByRole("dialog");
    fireEvent.change(screen.getByLabelText("Recipient Handle Or DID"), { target: { value: bob } });
    expect((screen.getByLabelText("First Message") as HTMLTextAreaElement).value).toBe(draft);
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(screen.getAllByRole("button", { name: "Send Message" }).at(-1)!);
    await waitFor(() => expect(write.mock.calls[0]![2].kind).toBe("start"));
    await waitFor(() => expect(write.mock.calls.some(call => call[2].kind === "send" && call[2].text === draft)).toBe(true));
    await waitFor(() => expect(screen.queryByRole("dialog") === null).toBe(true));
  });
  it("sends a native reply and adds/removes reactions through the selected conversation", async () => {
    const original = "👩‍💻".repeat(990);
    const message = { $type: "chat.bsky.convo.defs#messageView" as const, id: "m", rev: "2", text: original, sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z", reactions: [{ value: "👍", sender: { did: alice }, createdAt: "2026-10-10T00:00:00Z" }] };
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [convo] }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [message] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /bob.test/ }));
    fireEvent.click(await screen.findByRole("button", { name: "Message Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Reply" }));
    expect(screen.getByText("Replying To")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Short reply" } });
    expect((screen.getByRole("button", { name: "Send Message" }) as HTMLButtonElement).disabled).toBe(false);
    fireEvent.keyDown(screen.getByLabelText("Message"), { key: "Enter" });
    await waitFor(() => expect(write).toHaveBeenCalledTimes(1));
    const action = write.mock.calls[0]![2];
    expect(action.kind).toBe("send");
    if (action.kind === "send") expect(action).toEqual({ kind: "send", convoId: "c", text: "Short reply", replyTo: "m" });
    await waitFor(() => expect((screen.getByRole("button", { name: "Message Actions" }) as HTMLButtonElement).disabled).toBe(false));
    const reaction = screen.getByRole("button", { name: "Remove Reaction 👍" });
    expect(reaction.closest("article")).toBeNull();
    fireEvent.click(reaction);
    await waitFor(() => expect(write.mock.calls.some(call => call[2].kind === "removeReaction" && call[2].messageId === "m" && call[2].value === "👍")).toBe(true));
    await waitFor(() => expect((screen.getByRole("button", { name: "Message Actions" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(screen.getByRole("button", { name: "Message Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "React ❤️" }));
    await waitFor(() => expect(write.mock.calls.some(call => call[2].kind === "addReaction" && call[2].messageId === "m" && call[2].value === "❤️")).toBe(true));
  });
  it("renders the native immediate parent and keeps the composer outside the scrolling history", async () => {
    const parent = { $type: "chat.bsky.convo.defs#messageView" as const, id: "parent", rev: "1", text: "The text being replied to", sender: { did: alice }, sentAt: "2026-10-10T00:00:00Z" };
    const reply = { ...parent, id: "reply", text: "My response", sender: { did: bob }, replyTo: parent };
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [convo] }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [reply] }); restores.push(() => messages.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /bob.test/ }));
    expect(await screen.findByText("The text being replied to")).toBeTruthy();
    expect(screen.getByText("My response")).toBeTruthy();
    expect(screen.getAllByRole("separator")).toHaveLength(1);
    expect(document.querySelector("time")?.closest("article")).toBeNull();
    expect(screen.getByRole("button", { name: "Message Actions" }).closest("article")).toBeNull();
    const log = screen.getByRole("log", { name: "Conversation History" });
    const input = screen.getByLabelText("Message");
    const chatPane = screen.getByRole("region", { name: "Messages" });
    expect(chatPane.classList.contains("max-w-2xl")).toBe(true);
    expect(chatPane.classList.contains("w-full")).toBe(true);
    expect(chatPane.classList.contains("mx-auto")).toBe(true);
    expect(log.contains(input)).toBe(false);
    expect(log.className.includes("flex-1")).toBe(true);
    expect(input.closest("form")?.className.includes("shrink-0")).toBe(true);
    const contacts = screen.getByRole("complementary", { name: "Conversations" });
    expect(contacts.contains(screen.getByRole("button", { name: "New Conversation" }))).toBe(true);
    expect(contacts.contains(input)).toBe(false);
    expect(contacts.className.includes("md:col-start-2")).toBe(true);
    expect(contacts.className.includes("max-h-40")).toBe(true);
    expect(contacts.className.includes("floating-glass")).toBe(true);
  });
  for (const gesture of ["wheel", "touch"]) it(`loads older messages only after an upward ${gesture} gesture and preserves the visible position`, async () => {
    const message = { $type: "chat.bsky.convo.defs#messageView" as const, id: "new", rev: "1", text: "Recent message", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" };
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [convo] }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockImplementation(async args => args.cursor ? { messages: [{ ...message, id: "old", text: "Older message" }] } : { messages: [message], cursor: "older" }); restores.push(() => messages.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /bob.test/ }));
    await screen.findByText("Recent message");
    const log = screen.getByRole("log", { name: "Conversation History" });
    Object.defineProperty(log, "scrollHeight", { configurable: true, get: () => log.textContent?.includes("Older message") ? 400 : 200 });
    Object.defineProperty(log, "clientHeight", { configurable: true, value: 100 });
    expect(messages).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: "Older Messages" }) === null).toBe(true);
    log.scrollTop = 0;
    if (gesture === "wheel") { fireEvent.wheel(log, { deltaY: -10 }); fireEvent.wheel(log, { deltaY: -10 }); }
    else {
      fireEvent.touchStart(log, { touches: [{ clientX: 100, clientY: 100 }] });
      fireEvent.touchMove(log, { touches: [{ clientX: 150, clientY: 105 }] });
      expect(messages).toHaveBeenCalledTimes(1);
      fireEvent.touchStart(log, { touches: [{ clientX: 100, clientY: 100 }] });
      fireEvent.touchMove(log, { touches: [{ clientX: 102, clientY: 150 }] });
      fireEvent.touchMove(log, { touches: [{ clientX: 102, clientY: 180 }] });
    }
    await screen.findByText("Older message");
    expect(screen.getAllByRole("separator")).toHaveLength(1);
    expect(messages).toHaveBeenCalledTimes(2);
    expect(messages.mock.calls[1]![0].cursor).toBe("older");
    await waitFor(() => expect(log.scrollTop).toBe(200));
  });
  it("rejects noncanonical and unsafe post draft URLs", async () => {
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [convo] }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    for (const draft of ["javascript:alert(1)", "https://evil.test/profile/alice.test/post/one", "https://bsky.app@evil.test/profile/alice.test/post/one", "https://bsky.app/profile/alice.test/post/one?tracking=x", "https://bsky.app/profile/alice.test/post/one#fragment", "https://bsky.app/profile/alice.test/post/one/extra"]) {
      params.set("draft", draft);
      await mount();
      fireEvent.click(await screen.findByRole("button", { name: /bob.test/ }));
      expect((screen.getByLabelText("Message") as HTMLTextAreaElement).value).toBe("");
      cleanup(); client.clear();
    }
  });

});
