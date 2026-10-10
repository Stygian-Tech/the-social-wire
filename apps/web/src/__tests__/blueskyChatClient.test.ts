import { afterEach, describe, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Network from "@/lib/atprotoNetwork";
import { getBlueskyConversations, getBlueskyMessages, LOCAL_CHAT_UNAVAILABLE, performBlueskyChatAction, type ChatAction } from "@/lib/blueskyChatClient";
const did = "did:plc:abcdefghijklmnopqrstuvwx";
const peer = "did:plc:zzzzzzzzzzzzzzzzzzzzzzzz";
const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).forEach(restore => restore()));
const convo = { id: "conversation", rev: "1", members: [{ did, handle: "alice.test" }, { did: peer, handle: "bob.test" }], muted: false, unreadCount: 1 };
const message = { id: "message", rev: "2", text: "Hello", sender: { did }, sentAt: "2026-10-10T00:00:00Z" };
function configure(chatServiceDid?: string) {
  const config = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://appview.test", plcDirectory: "https://plc.test", handleResolver: "https://appview.test", appViewDid: "did:web:appview.test", chatServiceDid });
  restores.push(() => config.mockRestore());
}
describe("real chat protocol transport", () => {
  it("never sends local accounts to a public fallback and rejects identity drift before transport", async () => {
    configure();
    const session = { did, fetchHandler: async () => { throw new Error("unexpected transport"); } } as unknown as OAuthSession;
    await expect(getBlueskyConversations({ session, viewerDid: did })).rejects.toThrow(LOCAL_CHAT_UNAVAILABLE);
    await expect(getBlueskyConversations({ session, viewerDid: peer })).rejects.toThrow("account changed");
  });
  it("routes paginated reads through chat proxy with signal and all mutations with real RPC bodies", async () => {
    configure("did:web:chat.local.test");
    const signal = new AbortController().signal;
    const calls: { method: string; body?: Record<string, unknown> }[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://pds.test");
      expect(new Headers(init?.headers).get("atproto-proxy")).toBe("did:web:chat.local.test#bsky_chat");
      const method = url.pathname.split(".").at(-1)!;
      const body = init?.body ? JSON.parse(await new Response(init.body).text()) : undefined;
      calls.push({ method, body });
      if (method === "listConvos" || method === "getMessages") { expect(init?.signal).toBe(signal); expect(url.searchParams.get("cursor")).toBe("opaque+/="); }
      if (method === "listConvos") return Response.json({ convos: [convo], cursor: "next" });
      if (method === "getMessages") return Response.json({ messages: [{ ...message, $type: "chat.bsky.convo.defs#messageView" }], cursor: "older" });
      if (method === "sendMessage") return Response.json(message);
      if (method === "deleteMessageForSelf") return Response.json({ id: message.id, rev: "3", sender: { did }, sentAt: message.sentAt });
      return Response.json({ convo });
    } } as unknown as OAuthSession;
    expect((await getBlueskyConversations({ session, viewerDid: did, cursor: "opaque+/=", signal })).cursor).toBe("next");
    expect((await getBlueskyMessages({ session, viewerDid: did, convoId: convo.id, cursor: "opaque+/=", signal })).messages).toHaveLength(1);
    const actions: ChatAction[] = [{ kind: "start", members: [peer] }, { kind: "send", convoId: convo.id, text: " Hello " }, { kind: "read", convoId: convo.id, messageId: message.id }, { kind: "delete", convoId: convo.id, messageId: message.id }, { kind: "mute", convoId: convo.id }, { kind: "unmute", convoId: convo.id }];
    for (const action of actions) await performBlueskyChatAction(session, did, action);
    expect(calls.map(call => call.method)).toEqual(["listConvos", "getMessages", "getConvoForMembers", "sendMessage", "updateRead", "deleteMessageForSelf", "muteConvo", "unmuteConvo"]);
    expect(calls[3]!.body).toEqual({ convoId: convo.id, message: { text: "Hello" } });
    expect(calls[5]!.body).toEqual({ convoId: convo.id, messageId: message.id });
  });
  it("resolves recipient handles on the configured public resolver without OAuth", async () => {
    configure("did:web:chat.local.test");
    const resolve = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
      expect(url.origin).toBe("https://appview.test");
      expect(url.searchParams.get("handle")).toBe("bob.test");
      expect(new Headers(init?.headers).has("authorization")).toBe(false);
      return Response.json({ did: peer });
    }, { preconnect: globalThis.fetch.preconnect })); restores.push(() => resolve.mockRestore());
    const session = { did, fetchHandler: async (path: string) => {
      expect(new URL(path, "https://pds.test").searchParams.get("members")).toBe(peer);
      return Response.json({ convo });
    } } as unknown as OAuthSession;
    expect(await performBlueskyChatAction(session, did, { kind: "start", members: ["@bob.test"] })).toEqual({ convo });
  });
  it("rejects empty/oversized messages and malformed recipients before RPC", async () => {
    configure("did:web:chat.local.test");
    const session = { did, fetchHandler: async () => { throw new Error("unexpected transport"); } } as unknown as OAuthSession;
    for (const text of [" ", "x".repeat(1001)]) await expect(performBlueskyChatAction(session, did, { kind: "send", convoId: "c", text })).rejects.toThrow("1,000 characters");
    await expect(performBlueskyChatAction(session, did, { kind: "start", members: ["https://public.example"] })).rejects.toThrow("valid recipient handle or DID");
  });
});
