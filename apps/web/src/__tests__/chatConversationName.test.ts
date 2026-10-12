import { describe, expect, it } from "bun:test";
import type { ChatBskyConvoDefs } from "@atproto/api";
import { chatConversationName } from "@/lib/chatConversationName";

const convo: ChatBskyConvoDefs.ConvoView = { id: "group", rev: "1", members: [], unreadCount: 0, muted: false };
const kind = { $type: "chat.bsky.convo.defs#groupConvo", name: "  Project Chat  ", memberCount: 20, createdAt: "2026-10-11T00:00:00Z", lockStatus: "unlocked" } satisfies ChatBskyConvoDefs.GroupConvo;

describe("chatConversationName", () => {
  it("prefers the supplied group name over the partial member list", () => {
    expect(chatConversationName({ ...convo, kind }, ["Alice", "Bob"])).toBe("Project Chat");
  });
  it("falls back to safe member names for unnamed groups and direct conversations", () => {
    expect(chatConversationName({ ...convo, kind: { ...kind, name: "  " } }, ["Account", "Bob"])).toBe("Account, Bob");
    expect(chatConversationName(convo, ["Bob"])).toBe("Bob");
    expect(chatConversationName(convo, [])).toBe("Conversation");
  });
  it("does not use names from unknown conversation kinds", () => {
    expect(chatConversationName({ ...convo, kind: { $type: "future.convo", name: "Unrecognized" } as ChatBskyConvoDefs.ConvoView["kind"] }, ["Bob"])).toBe("Bob");
  });
});
