import { describe, expect, it } from "bun:test";
import type { ChatBskyConvoDefs } from "@atproto/api";
import { chatConversationPreview } from "@/lib/chatConversationPreview";

const message: NonNullable<ChatBskyConvoDefs.ConvoView["lastMessage"]> = { $type: "chat.bsky.convo.defs#messageView", id: "message", rev: "rev", text: "Hello\n  there", sender: { did: "did:plc:other" }, sentAt: "2026-10-11T00:00:00Z" };
describe("chat conversation previews", () => {
  it("collapses whitespace and identifies messages sent by the viewer", () => {
    expect(chatConversationPreview(message, "did:plc:viewer")).toBe("Hello there");
    expect(chatConversationPreview(message, "did:plc:other")).toBe("You: Hello there");
  });
  it("never exposes moderated text even from the viewer", () => {
    expect(chatConversationPreview(message, "did:plc:other", true)).toBe("Message Hidden");
  });
  it("handles missing, deleted, and unknown messages without rendering unknown text", () => {
    expect(chatConversationPreview(undefined, "viewer")).toBe("No Messages Yet");
    expect(chatConversationPreview({ ...message, $type: "chat.bsky.convo.defs#deletedMessageView" }, "viewer")).toBe("Message Deleted");
    expect(chatConversationPreview({ $type: "future.message", text: "Unknown private payload" } as NonNullable<ChatBskyConvoDefs.ConvoView["lastMessage"]>, "viewer")).toBe("Message Unavailable");
  });
  it("describes an empty shared post without omitting a viewer prefix", () => {
    expect(chatConversationPreview({ ...message, text: " ", embed: { $type: "app.bsky.embed.record#view" } }, "did:plc:other")).toBe("You: Shared Post");
    expect(chatConversationPreview({ ...message, text: " " }, "viewer")).toBe("Message");
  });
});
