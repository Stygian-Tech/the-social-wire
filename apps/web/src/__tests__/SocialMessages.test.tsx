import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Network from "@/lib/atprotoNetwork";
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
  params = new URLSearchParams();
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
    fireEvent.click(screen.getByRole("button", { name: "Delete For Me" }));
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
    fireEvent.change(screen.getByLabelText("Recipient Handle Or DID"), { target: { value: bob } });
    fireEvent.click(screen.getByRole("button", { name: "New Conversation" }));
    await waitFor(() => expect(write.mock.calls[0]![2].kind).toBe("start"));
    await waitFor(() => expect((screen.getByLabelText("Recipient Handle Or DID") as HTMLInputElement).value).toBe(""));
    expect((screen.getByLabelText("Message") as HTMLTextAreaElement).value).toBe(draft);
    expect(write.mock.calls.some(call => call[2].kind === "send")).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
    await waitFor(() => expect(write.mock.calls.some(call => call[2].kind === "send" && call[2].text === draft)).toBe(true));
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
