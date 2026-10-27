import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
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
// Control only the dwell timers; React Query and Testing Library keep real timers.
function pageReadClock() {
  let now = 0;
  let nextId = -1;
  const scheduled = new Map<number, { due: number; callback: () => void }>();
  const originalTimeout = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  const visibility = Object.getOwnPropertyDescriptor(document, "visibilityState");
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  restores.push(() => { if (visibility) Object.defineProperty(document, "visibilityState", visibility); else Reflect.deleteProperty(document, "visibilityState"); });
  globalThis.setTimeout = ((callback: () => void, delay?: number, ...args: unknown[]) => {
    if (delay !== 2_000) return originalTimeout(callback, delay, ...args);
    const id = nextId--; scheduled.set(id, { due: now + delay, callback });
    return id;
  }) as typeof setTimeout;
  globalThis.clearTimeout = (id => {
    if (!scheduled.delete(Number(id))) originalClear(id as Parameters<typeof clearTimeout>[0]);
  }) as typeof clearTimeout;
  restores.push(() => { globalThis.setTimeout = originalTimeout; globalThis.clearTimeout = originalClear; });
  return {
    get pending() { return scheduled.size; },
    async advance(milliseconds: number) {
      now += milliseconds;
      await act(async () => {
        for (const [id, timer] of scheduled) {
          if (timer.due <= now) { scheduled.delete(id); timer.callback(); }
        }
      });
    },
  };
}
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
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
async function mount() { await act(async () => { render(<QueryClientProvider client={client}><SidebarProvider><SocialMessages /></SidebarProvider></QueryClientProvider>); }); }
it("automatically reads the selected accepted conversation after two seconds through its newest loaded message", async () => {
  const clock = pageReadClock();
  let current = convo;
  const newest = { $type: "chat.bsky.convo.defs#messageView" as const, id: "newest", rev: "3", text: "Newest loaded message", sender: { did: bob }, sentAt: "2026-10-10T01:00:00Z" };
  const older = { ...newest, id: "older", text: "Older loaded message", sentAt: "2026-10-10T00:00:00Z" };
  const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [current] })); restores.push(() => list.mockRestore());
  const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [newest, older] }); restores.push(() => messages.mockRestore());
  const write = spyOn(Chat, "performBlueskyChatAction").mockImplementation(async () => { current = { ...convo, unreadCount: 0 }; return { convo: current }; }); restores.push(() => write.mockRestore());
  await mount();
  expect(clock.pending).toBe(0);
  fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
  await screen.findByText("Newest loaded message");
  await waitFor(() => expect(clock.pending).toBe(1));
  await clock.advance(1_999);
  expect(write).not.toHaveBeenCalled();
  await clock.advance(1);
  await waitFor(() => expect(write).toHaveBeenCalledTimes(1));
  expect(write.mock.calls[0]![0].did).toBe(alice);
  expect(write.mock.calls[0]![2]).toEqual({ kind: "read", convoId: "c", messageId: "newest" });
  await waitFor(() => expect(screen.getByRole("button", { name: /^(?!More Actions).*bob\.test/ }).textContent).not.toContain("1"));
  await clock.advance(2_000);
  expect(write).toHaveBeenCalledTimes(1);
});

it("does not start message auto-read before history loads or for a pending request", async () => {
  const clock = pageReadClock();
  const request = { ...convo, id: "pending-conversation", status: "request" };
  const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [request] : [convo] })); restores.push(() => list.mockRestore());
  let resolve!: (page: Awaited<ReturnType<typeof Chat.getBlueskyMessages>>) => void;
  const pending = new Promise<Awaited<ReturnType<typeof Chat.getBlueskyMessages>>>(done => { resolve = done; });
  const messages = spyOn(Chat, "getBlueskyMessages").mockReturnValue(pending); restores.push(() => messages.mockRestore());
  const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
  await mount();
  fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
  await waitFor(() => expect(messages).toHaveBeenCalledTimes(1));
  await clock.advance(2_000);
  expect(clock.pending).toBe(0);
  expect(write).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Pending (1)" }));
  fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
  await act(async () => resolve({ messages: [{ $type: "chat.bsky.convo.defs#messageView", id: "pending", rev: "1", text: "Pending message", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" }] }));
  await screen.findByRole("region", { name: "Message Request" });
  await clock.advance(2_000);
  expect(clock.pending).toBe(0);
  expect(write).not.toHaveBeenCalled();
});

it("cancels message auto-read when navigating away before the delay", async () => {
  const clock = pageReadClock();
  const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
  const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [{ $type: "chat.bsky.convo.defs#messageView", id: "m", rev: "1", text: "Leave before reading", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" }] }); restores.push(() => messages.mockRestore());
  const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
  await mount();
  fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
  await screen.findByText("Leave before reading");
  await waitFor(() => expect(clock.pending).toBe(1));
  await clock.advance(1_000);
  cleanup();
  expect(clock.pending).toBe(0);
  await clock.advance(2_000);
  expect(write).not.toHaveBeenCalled();
});

it("retains conversation unread state when automatic upstream read fails", async () => {
  const clock = pageReadClock();
  const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
  const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [{ $type: "chat.bsky.convo.defs#messageView", id: "m", rev: "1", text: "Read failure", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" }] }); restores.push(() => messages.mockRestore());
  const write = spyOn(Chat, "performBlueskyChatAction").mockRejectedValue(new Error("Upstream read unavailable")); restores.push(() => write.mockRestore());
  await mount();
  fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
  await screen.findByText("Read failure");
  await waitFor(() => expect(clock.pending).toBe(1));
  await clock.advance(2_000);
  await screen.findByRole("alert");
  expect(screen.getByRole("button", { name: /^(?!More Actions).*bob\.test/ }).textContent).toContain("1");
  await clock.advance(2_000);
  expect(write).toHaveBeenCalledTimes(1);
});
describe("Messages workspace", () => {
  it("uses the supplied group name in the list, header, and deletion confirmation", async () => {
    const group = { ...convo, kind: { $type: "chat.bsky.convo.defs#groupConvo" as const, name: "Project Chat", memberCount: 20, createdAt: "2026-10-11T00:00:00Z", lockStatus: "unlocked" } };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [group] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo: group }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*Project Chat/ }));
    expect(await screen.findByRole("heading", { name: "Project Chat" })).toBeTruthy();
    expect(screen.getByText("20 Participants")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Conversation Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Delete Conversation" }));
    const dialog = await screen.findByRole("dialog", { name: "Delete Conversation?" });
    expect(within(dialog).getByText("This deletes “Project Chat” for you. Other participants keep their messages.")).toBeTruthy();
    expect(write).not.toHaveBeenCalledWith(expect.anything(), expect.anything(), expect.objectContaining({ kind: "leave" }));
  });
  it("shows the local service limitation without requesting chats", async () => {
    const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://appview.test", plcDirectory: "https://plc.test", handleResolver: "https://appview.test", appViewDid: "did:web:appview.test" }); restores.push(() => network.mockRestore());
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [] }); restores.push(() => list.mockRestore());
    await mount();
    expect(screen.getByText("Messages Unavailable Locally")).toBeTruthy();
    expect(list).not.toHaveBeenCalled();
  });
  it("opens actual conversations, sends, marks read, mutes, and confirms delete-for-self", async () => {
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [{ $type: "chat.bsky.convo.defs#messageView", id: "m", rev: "2", text: "Received Message", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" }] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
    expect(await screen.findByText("Received Message")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Outgoing" } });
    fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
    await waitFor(() => expect(write.mock.calls[0]![2]).toEqual({ kind: "send", convoId: "c", text: "Outgoing" }));
    await waitFor(() => expect((screen.getByLabelText("Message") as HTMLTextAreaElement).value).toBe(""));
    fireEvent.click(screen.getByRole("button", { name: "Conversation Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Mark As Read" }));
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
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    await mount();
    expect(await screen.findByText("Your account changed. Please reload Messages.")).toBeTruthy();
    expect(list).not.toHaveBeenCalled();
  });
  it("retains a shared post draft through existing and new recipient selection and sends only explicitly", async () => {
    const draft = `https://bsky.app/profile/${encodeURIComponent(bob)}/post/shared`;
    params.set("draft", draft);
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
    await mount();
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
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
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [message] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
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
    const observed = new Map<Element, () => void>();
    const observerDescriptor = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
    Object.defineProperty(globalThis, "ResizeObserver", { configurable: true, value: class {
      constructor(private callback: () => void) {}
      observe(element: Element) { observed.set(element, this.callback); }
      disconnect() {}
    } });
    restores.push(() => { if (observerDescriptor) Object.defineProperty(globalThis, "ResizeObserver", observerDescriptor); else Reflect.deleteProperty(globalThis, "ResizeObserver"); });
    const parent = { $type: "chat.bsky.convo.defs#messageView" as const, id: "parent", rev: "1", text: "The text being replied to", sender: { did: alice }, sentAt: "2026-10-10T00:00:00Z" };
    const reply = { ...parent, id: "reply", text: "My response", sender: { did: bob }, replyTo: parent };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [reply] }); restores.push(() => messages.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
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
    const footer = input.closest("form")!.parentElement!;
    expect(log.nextElementSibling).toBe(footer);
    expect(log.getAttribute("data-floating-glass-scroll-bottom")).toBe("true");
    let footerHeight = 48;
    footer!.style.marginTop = "12px";
    footer!.getBoundingClientRect = () => ({ height: footerHeight }) as DOMRect;
    observed.get(footer!)?.();
    expect(chatPane.style.getPropertyValue("--floating-glass-bottom-extent")).toBe("60px");
    footerHeight = 160;
    observed.get(footer!)?.();
    expect(chatPane.style.getPropertyValue("--floating-glass-bottom-extent")).toBe("172px");
    fireEvent.click(screen.getByRole("button", { name: "Message Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Delete For Me" }));
    expect(log.nextElementSibling).toBe(footer);
    expect(footer!.contains(screen.getByRole("alert"))).toBe(true);
    expect(log.getAttribute("data-floating-glass-scroll-bottom")).toBe("true");
    const contacts = screen.getByRole("complementary", { name: "Conversations" });
    expect(contacts.contains(screen.getByRole("button", { name: "New Conversation" }))).toBe(true);
    expect(contacts.contains(input)).toBe(false);
    expect(contacts.className.includes("md:col-start-2")).toBe(true);
    expect(contacts.className.includes("max-h-64")).toBe(true);
    expect(contacts.className.includes("floating-glass")).toBe(true);
  });
  for (const gesture of ["wheel", "touch"]) it(`loads older messages only after an upward ${gesture} gesture and preserves the visible position`, async () => {
    const message = { $type: "chat.bsky.convo.defs#messageView" as const, id: "new", rev: "1", text: "Recent message", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockImplementation(async args => args.cursor ? { messages: [{ ...message, id: "old", text: "Older message" }] } : { messages: [message], cursor: "older" }); restores.push(() => messages.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
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
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    for (const draft of ["javascript:alert(1)", "https://evil.test/profile/alice.test/post/one", "https://bsky.app@evil.test/profile/alice.test/post/one", "https://bsky.app/profile/alice.test/post/one?tracking=x", "https://bsky.app/profile/alice.test/post/one#fragment", "https://bsky.app/profile/alice.test/post/one/extra"]) {
      params.set("draft", draft);
      await mount();
      fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
      expect((screen.getByLabelText("Message") as HTMLTextAreaElement).value).toBe("");
      cleanup(); client.clear();
    }
  });

  it("keeps pending requests separate and requires acceptance before replying", async () => {
    let accepted = false;
    const request = { ...convo, status: "request", lastMessage: { $type: "chat.bsky.convo.defs#messageView" as const, id: "m", rev: "1", text: "A pending hello", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" } };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? accepted ? [] : [request] : accepted ? [{ ...request, status: "accepted" }] : [] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [request.lastMessage] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockImplementation(async (_session, _did, action) => { if (action.kind === "accept") accepted = true; return { convo: { ...request, status: "accepted" } }; }); restores.push(() => write.mockRestore());
    await mount();
    expect(list.mock.calls.map(call => call[0].status).sort()).toEqual(["accepted", "request"]);
    expect(screen.queryByRole("button", { name: /^(?!More Actions).*bob\.test/ })).toBeNull();
    fireEvent.click(await screen.findByRole("button", { name: "Pending (1)" }));
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
    await screen.findByRole("region", { name: "Message Request" });
    expect(screen.queryByLabelText("Message")).toBeNull();
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Accept Request" }));
    await screen.findByLabelText("Message");
    expect(write.mock.calls[0]![2]).toEqual({ kind: "accept", convoId: "c" });
    expect(screen.queryByRole("region", { name: "Message Request" })).toBeNull();
    expect(screen.getByRole("button", { name: "Chats" }).getAttribute("aria-pressed")).toBe("true");
  });
  it("leaves a failed acceptance pending with no reply composer", async () => {
    const request = { ...convo, status: "request" };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [request] : [] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockRejectedValue(new Error("Acceptance unavailable")); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: "Pending (1)" }));
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
    fireEvent.click(await screen.findByRole("button", { name: "Accept Request" }));
    await screen.findByRole("alert");
    expect(screen.queryByLabelText("Message")).toBeNull();
    expect(screen.getByRole("region", { name: "Message Request" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Pending (1)" }).getAttribute("aria-pressed")).toBe("true");
    expect(write.mock.calls[0]![2]).toEqual({ kind: "accept", convoId: "c" });
  });
  it("requires confirmation before deleting a conversation and removes it after success", async () => {
    let removed = false;
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" || removed ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockImplementation(async () => { removed = true; return { convo }; }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
    fireEvent.click(screen.getByRole("button", { name: "Conversation Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Delete Conversation" }));
    const dialog = await screen.findByRole("dialog", { name: "Delete Conversation?" });
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Conversation Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Delete Conversation" }));
    const confirmation = await screen.findByRole("dialog", { name: "Delete Conversation?" });
    fireEvent.click(within(confirmation).getByRole("button", { name: "Delete Conversation" }));
    await waitFor(() => expect(write.mock.calls[0]![2]).toEqual({ kind: "leave", convoId: "c" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(screen.queryByRole("button", { name: /^(?!More Actions).*bob\.test/ })).toBeNull();
    expect(screen.queryByLabelText("Message")).toBeNull();
  });
  it("reflects mute and unmute server state in the sidebar and conversation header", async () => {
    let current = convo;
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [current] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockImplementation(async (_session, _did, action) => { current = { ...current, muted: action.kind === "mute" }; return { convo: current }; }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
    fireEvent.click(screen.getByRole("button", { name: "Mute" }));
    await screen.findByRole("button", { name: "Unmute" });
    expect(within(screen.getByRole("complementary", { name: "Conversations" })).getByRole("img", { name: "Muted Conversation" })).toBeTruthy();
    expect(screen.getByText("Muted Conversation")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Unmute" }));
    await screen.findByRole("button", { name: "Mute" });
    expect(screen.queryByRole("img", { name: "Muted Conversation" })).toBeNull();
    expect(screen.getByText("Private Conversation")).toBeTruthy();
    expect(write.mock.calls.map(call => call[2].kind)).toEqual(["mute", "unmute"]);
  });
  it("sends a message report only on explicit submission and announces success", async () => {
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [convo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [{ $type: "chat.bsky.convo.defs#messageView", id: "m", rev: "1", text: "Report this message", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" }] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
    fireEvent.click(await screen.findByRole("button", { name: "Message Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Report Message" }));
    await screen.findByRole("dialog", { name: "Report Chat" });
    expect(write).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText("Reason"), { target: { value: "com.atproto.moderation.defs#reasonViolation" } });
    fireEvent.change(screen.getByLabelText("Additional Details"), { target: { value: "Repeated harassment" } });
    expect(write).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Send Report" }));
    await screen.findByText("Report Sent to Bluesky Moderation.");
    expect(write.mock.calls[0]![2]).toEqual({ kind: "report", convoId: "c", senderDid: bob, messageId: "m", reasonType: "com.atproto.moderation.defs#reasonViolation", reason: "Repeated harassment" });
    expect(screen.queryByRole("dialog", { name: "Report Chat" })).toBeNull();
  });
  it("hides blocked sender text in both sidebar previews and message bodies", async () => {
    const message = { $type: "chat.bsky.convo.defs#messageView" as const, id: "m", rev: "1", text: "Private blocked content", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" };
    const blockedConvo = { ...convo, members: [convo.members[0]!, { ...convo.members[1]!, viewer: { blockedBy: true } }], lastMessage: message };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [blockedConvo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [message] }); restores.push(() => messages.mockRestore());
    await mount();
    expect(await screen.findByText("Message Hidden")).toBeTruthy();
    expect(screen.queryByText("Private blocked content")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: /^(?!More Actions).*Account/ }));
    await screen.findByText("Message Hidden by Your Moderation Settings");
    expect(screen.queryByText("Private blocked content")).toBeNull();
    expect(screen.queryByRole("button", { name: "Show Message" })).toBeNull();
  });

  it("hides a blocked sender quote inside the viewer's otherwise safe message", async () => {
    const parent = { $type: "chat.bsky.convo.defs#messageView" as const, id: "blocked-parent", rev: "1", text: "Blocked quoted text", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" };
    const reply = { ...parent, id: "safe-reply", text: "My safe response", sender: { did: alice }, replyTo: parent };
    const blockedConvo = { ...convo, members: [convo.members[0]!, { ...convo.members[1]!, viewer: { blockedBy: true } }] };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [blockedConvo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [reply] }); restores.push(() => messages.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*Account/ }));
    await screen.findByText("My safe response");
    const quoted = screen.getByRole("blockquote", { name: "Replied-To Message" });
    expect(within(quoted).getByText("Message Hidden by Your Moderation Settings")).toBeTruthy();
    expect(screen.queryByText("Blocked quoted text")).toBeNull();
  });
  it("prevents sending and reacting in a blocked direct conversation", async () => {
    const own = { $type: "chat.bsky.convo.defs#messageView" as const, id: "own", rev: "1", text: "My previous message", sender: { did: alice }, sentAt: "2026-10-10T00:00:00Z", reactions: [{ value: "👍", sender: { did: alice }, createdAt: "2026-10-10T00:00:00Z" }] };
    const blockedConvo = { ...convo, members: [convo.members[0]!, { ...convo.members[1]!, viewer: { blockedBy: true } }] };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [blockedConvo] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [own] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo: blockedConvo }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*Account/ }));
    await screen.findByText("My previous message");
    expect(screen.queryByLabelText("Message")).toBeNull();
    expect(screen.queryByRole("button", { name: "Send Message" })).toBeNull();
    expect(screen.getByText("This Conversation Is Not Available for Replies.")).toBeTruthy();
    const reaction = screen.getByRole("button", { name: "Remove Reaction 👍" }) as HTMLButtonElement;
    expect(reaction.disabled).toBe(true);
    fireEvent.click(reaction);
    fireEvent.click(screen.getByRole("button", { name: "Message Actions" }));
    await screen.findByRole("menuitem", { name: "Delete For Me" });
    expect(screen.getByRole("menuitem", { name: "Reply" }).getAttribute("aria-disabled")).toBe("true");
    expect(screen.getByRole("menuitem", { name: "React ❤️" }).getAttribute("aria-disabled")).toBe("true");
    expect(write).not.toHaveBeenCalled();
  });
  it("keeps an unlocked group composer available for safe members when one member is blocked", async () => {
    const charlie = "did:plc:yyyyyyyyyyyyyyyyyyyyyyyy";
    const group = { ...convo, members: [convo.members[0]!, { ...convo.members[1]!, viewer: { blockedBy: true } }, { did: charlie, handle: "charlie.test" }], kind: { $type: "chat.bsky.convo.defs#groupConvo" as const, name: "Group", memberCount: 3, createdAt: "2026-10-10T00:00:00Z", lockStatus: "unlocked" } };
    const safeMessage = { $type: "chat.bsky.convo.defs#messageView" as const, id: "safe", rev: "1", text: "Safe group message", sender: { did: charlie }, sentAt: "2026-10-10T00:00:00Z" };
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [group] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [safeMessage] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockResolvedValue({ convo: group }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*Group/ }));
    await screen.findByText("Safe group message");
    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Reply to the group" } });
    fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
    await waitFor(() => expect(write.mock.calls[0]![2]).toEqual({ kind: "send", convoId: "c", text: "Reply to the group" }));
  });

  it("confirms block and unblock, then respects a later server-side block", async () => {
    let serverBlocked = false;
    const message = { $type: "chat.bsky.convo.defs#messageView" as const, id: "m", rev: "1", text: "Peer message contents", sender: { did: bob }, sentAt: "2026-10-10T00:00:00Z" };
    const serverConvo = () => ({ ...convo, members: [convo.members[0]!, { ...convo.members[1]!, viewer: { blocking: serverBlocked ? `at://${alice}/app.bsky.graph.block/peer` : undefined } }], lastMessage: message });
    const list = spyOn(Chat, "getBlueskyConversations").mockImplementation(async args => ({ convos: args.status === "request" ? [] : [serverConvo()] })); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [message] }); restores.push(() => messages.mockRestore());
    const write = spyOn(Chat, "performBlueskyChatAction").mockImplementation(async (_session, _did, action) => { if (action.kind === "block" || action.kind === "unblock") serverBlocked = action.kind === "block"; return { convo: serverConvo() }; }); restores.push(() => write.mockRestore());
    await mount();
    fireEvent.click(await screen.findByRole("button", { name: /^(?!More Actions).*bob\.test/ }));
    await within(screen.getByRole("log", { name: "Conversation History" })).findByText("Peer message contents");
    fireEvent.click(screen.getByRole("button", { name: "Conversation Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Block Account" }));
    const blockDialog = await screen.findByRole("dialog", { name: "Block Account?" });
    expect(write).not.toHaveBeenCalled();
    expect(screen.queryByText("Message Hidden by Your Moderation Settings")).toBeNull();
    fireEvent.click(within(blockDialog).getByRole("button", { name: "Block Account" }));
    await screen.findByText("Message Hidden by Your Moderation Settings");
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(write.mock.calls[0]![2]).toEqual({ kind: "block", convoId: "c", subjectDid: bob });
    expect(screen.queryByText("Peer message contents")).toBeNull();
    expect(screen.queryByLabelText("Message")).toBeNull();
    expect(screen.getByText("Message Hidden")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Conversation Actions" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Unblock Account" }));
    const unblockDialog = await screen.findByRole("dialog", { name: "Unblock Account?" });
    expect(write).toHaveBeenCalledTimes(1);
    fireEvent.click(within(unblockDialog).getByRole("button", { name: "Unblock Account" }));
    await screen.findByLabelText("Message");
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(write.mock.calls[1]![2]).toEqual({ kind: "unblock", convoId: "c", subjectDid: bob });
    expect(within(screen.getByRole("log", { name: "Conversation History" })).getByText("Peer message contents")).toBeTruthy();
    expect(screen.queryByText("Message Hidden")).toBeNull();
    serverBlocked = true;
    await act(async () => { await client.invalidateQueries({ queryKey: ["blueskySocial", alice, "messages", 0, "conversations"] }); });
    await screen.findByText("Message Hidden by Your Moderation Settings");
    expect(screen.queryByLabelText("Message")).toBeNull();
    expect(screen.queryByText("Peer message contents")).toBeNull();
    expect(write).toHaveBeenCalledTimes(2);
    fireEvent.click(screen.getByRole("button", { name: "Conversation Actions" }));
    expect(await screen.findByRole("menuitem", { name: "Unblock Account" })).toBeTruthy();
  });

});
