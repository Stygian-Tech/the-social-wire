import { afterEach, describe, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Network from "@/lib/atprotoNetwork";
import { getBlueskyConversations, getBlueskyMessageUnread, getBlueskyMessages, LOCAL_CHAT_UNAVAILABLE, performBlueskyChatAction, chatErrorMessage, type ChatAction } from "@/lib/blueskyChatClient";
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
  it("filters requests and accepts or leaves with the actual endpoint response shapes", async () => {
    configure("did:web:chat.local.test");
    const calls: string[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://pds.test");
      const method = url.pathname.split(".").at(-1)!;
      calls.push(method);
      if (method === "listConvos") { expect(url.searchParams.get("status")).toBe("request"); return Response.json({ convos: [{ ...convo, status: "request" }] }); }
      expect(JSON.parse(await new Response(init?.body).text())).toEqual({ convoId: convo.id });
      return Response.json(method === "acceptConvo" ? { rev: "accepted" } : { convoId: convo.id, rev: "left" });
    } } as unknown as OAuthSession;
    await getBlueskyConversations({ session, viewerDid: did, status: "request" });
    expect(await performBlueskyChatAction(session, did, { kind: "accept", convoId: convo.id })).toEqual({ rev: "accepted" });
    expect(await performBlueskyChatAction(session, did, { kind: "leave", convoId: convo.id })).toMatchObject({ convoId: convo.id, rev: "left" });
    expect(calls).toEqual(["listConvos", "acceptConvo", "leaveConvo"]);
  });
  it("reports private chat subjects to Bluesky moderation and fails closed on local networks", async () => {
    configure("did:web:api.bsky.chat");
    const subjects: unknown[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      expect(new URL(path, "https://pds.test").pathname).toBe("/xrpc/com.atproto.moderation.createReport");
      expect(new Headers(init?.headers).get("atproto-proxy")).toBe("did:plc:ar7c4by46qjdydhdevvrndac#atproto_labeler");
      const body = JSON.parse(await new Response(init?.body).text());
      expect(body.reason).toBe("Unwanted messages");
      subjects.push(body.subject);
      return Response.json({ id: 1, reasonType: body.reasonType, subject: body.subject, reportedBy: did, createdAt: message.sentAt });
    } } as unknown as OAuthSession;
    const report = { kind: "report" as const, convoId: convo.id, senderDid: peer, reasonType: "com.atproto.moderation.defs#reasonSpam", reason: " Unwanted messages " };
    await performBlueskyChatAction(session, did, { ...report, messageId: message.id });
    await performBlueskyChatAction(session, did, report);
    expect(subjects).toEqual([{ $type: "chat.bsky.convo.defs#messageRef", did: peer, convoId: convo.id, messageId: message.id }, { $type: "chat.bsky.convo.defs#convoRef", did: peer, convoId: convo.id }]);
    await expect(performBlueskyChatAction(session, did, { ...report, reasonType: "invalid" })).rejects.toThrow("valid report reason");
    await expect(performBlueskyChatAction(session, did, { ...report, reason: "a".repeat(2001) })).rejects.toThrow("2,000");
    configure("did:web:chat.local.test");
    await expect(performBlueskyChatAction(session, did, report)).rejects.toThrow("no chat moderation service");
    expect(subjects).toHaveLength(2);
  });
  it("writes blocks to PDS and validates unblock record ownership and viewer identity", async () => {
    configure("did:web:chat.local.test");
    let blocking = `at://${did}/app.bsky.graph.block/block-key`;
    let current = true;
    let drift = false;
    const writes: { method: string; body: unknown }[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const method = new URL(path, "https://pds.test").pathname.split(".").at(-1)!;
      if (method === "getProfile") { if (drift) current = false; return Response.json({ did: peer, handle: "bob.test", viewer: { blocking } }); }
      expect(new Headers(init?.headers).has("atproto-proxy")).toBe(false);
      writes.push({ method, body: JSON.parse(await new Response(init?.body).text()) });
      return Response.json(method === "createRecord" ? { uri: blocking, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" } : {});
    } } as unknown as OAuthSession;
    await performBlueskyChatAction(session, did, { kind: "block", convoId: convo.id, subjectDid: peer });
    expect(writes[0].body).toMatchObject({ repo: did, collection: "app.bsky.graph.block", record: { subject: peer, $type: "app.bsky.graph.block" } });
    await performBlueskyChatAction(session, did, { kind: "unblock", convoId: convo.id, subjectDid: peer });
    expect(writes[1].body).toEqual({ repo: did, collection: "app.bsky.graph.block", rkey: "block-key" });
    blocking = `at://${peer}/app.bsky.graph.block/key`;
    await expect(performBlueskyChatAction(session, did, { kind: "unblock", convoId: convo.id, subjectDid: peer })).rejects.toThrow("does not belong");
    blocking = `at://${did}/app.bsky.graph.block/key`;
    drift = true;
    await expect(performBlueskyChatAction(session, did, { kind: "unblock", convoId: convo.id, subjectDid: peer }, () => { if (!current) throw new Error("Your account changed"); })).rejects.toThrow("account changed");
    expect(writes).toHaveLength(2);
  });
  it("unblocks a newly created PDS record before the AppView replica catches up", async () => {
    configure("did:web:chat.local.test");
    const calls: string[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const method = new URL(path, "https://pds.test").pathname.split(".").at(-1)!;
      calls.push(method);
      if (method === "getProfile") throw new Error("The replica has not indexed this block yet");
      expect(JSON.parse(await new Response(init?.body).text())).toEqual({ repo: did, collection: "app.bsky.graph.block", rkey: "fresh-block" });
      return Response.json({});
    } } as unknown as OAuthSession;
    await performBlueskyChatAction(session, did, { kind: "unblock", convoId: convo.id, subjectDid: peer, blockingUri: `at://${did}/app.bsky.graph.block/fresh-block` });
    expect(calls).toEqual(["deleteRecord"]);
    await expect(performBlueskyChatAction(session, did, { kind: "unblock", convoId: convo.id, subjectDid: peer, blockingUri: `at://${peer}/app.bsky.graph.block/fresh-block` })).rejects.toThrow("does not belong");
    expect(calls).toEqual(["deleteRecord"]);
  });
  it("never sends local accounts to a public fallback and rejects identity drift before transport", async () => {
    configure();
    const session = { did, fetchHandler: async () => { throw new Error("unexpected transport"); } } as unknown as OAuthSession;
    await expect(getBlueskyConversations({ session, viewerDid: did })).rejects.toThrow(LOCAL_CHAT_UNAVAILABLE);
    await expect(getBlueskyConversations({ session, viewerDid: peer })).rejects.toThrow("account changed");
  });
  it("counts all unread pages without fetching messages or double-counting overlapping conversations", async () => {
    configure("did:web:chat.local.test");
    const cursors: (string | null)[] = [];
    const signal = new AbortController().signal;
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://pds.test");
      expect(url.pathname).toBe("/xrpc/chat.bsky.convo.listConvos");
      expect(url.searchParams.get("readState")).toBe("unread");
      expect(init?.signal).toBe(signal);
      cursors.push(url.searchParams.get("cursor"));
      return cursors.length === 1 ? Response.json({ convos: [{ ...convo, unreadCount: 3 }], cursor: "next" }) : Response.json({ convos: [{ ...convo, unreadCount: 3 }, { ...convo, id: "other", unreadCount: 4 }] });
    } } as unknown as OAuthSession;
    expect(await getBlueskyMessageUnread({ session, viewerDid: did, signal })).toBe(7);
    expect(cursors).toEqual([null, "next"]);
  });
  it("rejects incomplete unread pagination instead of presenting a partial total", async () => {
    configure("did:web:chat.local.test");
    const session = { did, fetchHandler: async () => Response.json({ convos: [convo], cursor: "same" }) } as unknown as OAuthSession;
    await expect(getBlueskyMessageUnread({ session, viewerDid: did })).rejects.toThrow("pagination did not complete");
    const controller = new AbortController(); controller.abort();
    await expect(getBlueskyMessageUnread({ session, viewerDid: did, signal: controller.signal })).rejects.toThrow();
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
  it("sends native reply references and resolves mention/link facets with UTF-8 offsets", async () => {
    configure("did:web:chat.local.test");
    let sent: Record<string, unknown> | undefined;
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://pds.test");
      if (url.pathname.endsWith("resolveHandle")) return Response.json({ did: peer });
      sent = JSON.parse(await new Response(init?.body).text());
      return Response.json(message);
    } } as unknown as OAuthSession;
    await performBlueskyChatAction(session, did, { kind: "send", convoId: "c", text: "😀 @bob.test https://example.test", replyTo: "parent" });
    const payload = sent?.message as { text: string; replyTo: { messageId: string }; facets: { index: { byteStart: number }; features: { did?: string; uri?: string }[] }[] };
    expect(payload.replyTo).toEqual({ messageId: "parent" });
    expect(payload.text).toBe("😀 @bob.test https://example.test");
    expect(payload.facets.find(facet => facet.features[0].did === peer)?.index.byteStart).toBe(5);
    expect(payload.facets.some(facet => facet.features[0].uri === "https://example.test")).toBe(true);
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
  it("uses narrow real reaction RPCs and rejects unsupported values before writing", async () => {
    configure("did:web:chat.local.test");
    const calls: { method: string; body: unknown }[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://pds.test");
      expect(new Headers(init?.headers).get("atproto-proxy")).toBe("did:web:chat.local.test#bsky_chat");
      calls.push({ method: url.pathname.split(".").at(-1)!, body: JSON.parse(await new Response(init?.body).text()) });
      return Response.json({ message: { ...message, $type: "chat.bsky.convo.defs#messageView" } });
    } } as unknown as OAuthSession;
    await performBlueskyChatAction(session, did, { kind: "addReaction", convoId: "c", messageId: "m", value: "❤️" });
    await performBlueskyChatAction(session, did, { kind: "removeReaction", convoId: "c", messageId: "m", value: "❤️" });
    expect(calls).toEqual([{ method: "addReaction", body: { convoId: "c", messageId: "m", value: "❤️" } }, { method: "removeReaction", body: { convoId: "c", messageId: "m", value: "❤️" } }]);
    await expect(performBlueskyChatAction(session, did, { kind: "addReaction", convoId: "c", messageId: "m", value: "invalid" })).rejects.toThrow("valid message reaction");
    expect(calls).toHaveLength(2);
  });
  it("checks the live viewer again after handle resolution before opening a conversation", async () => {
    configure("did:web:chat.local.test");
    let current = true;
    const resolve = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async () => { current = false; return Response.json({ did: peer }); }, { preconnect: globalThis.fetch.preconnect })); restores.push(() => resolve.mockRestore());
    let writes = 0;
    const session = { did, fetchHandler: async () => { writes++; return Response.json({ convo }); } } as unknown as OAuthSession;
    await expect(performBlueskyChatAction(session, did, { kind: "start", members: ["bob.test"] }, () => { if (!current) throw new Error("Your account changed"); })).rejects.toThrow("account changed");
    expect(writes).toBe(0);
  });
  it("rejects empty/oversized messages and malformed recipients before RPC", async () => {
    configure("did:web:chat.local.test");
    const session = { did, fetchHandler: async () => { throw new Error("unexpected transport"); } } as unknown as OAuthSession;
    for (const text of [" ", "x".repeat(1001)]) await expect(performBlueskyChatAction(session, did, { kind: "send", convoId: "c", text })).rejects.toThrow("1,000 characters");
    await expect(performBlueskyChatAction(session, did, { kind: "start", members: ["https://public.example"] })).rejects.toThrow("valid recipient handle or DID");
  });
});

describe("chat errors", () => {
  it("preserves actionable account/validation errors without exposing upstream details", () => {
    expect(chatErrorMessage(new Error("Your account changed. Please reload Messages."))).toBe("Your account changed. Please reload Messages.");
    expect(chatErrorMessage(new Error("Report details must be at most 2,000 characters."))).toBe("Report details must be at most 2,000 characters.");
    expect(chatErrorMessage(new Error("upstream database credentials and private request payload"))).toBe("Messages could not be loaded or updated. Please retry.");
  });
});
