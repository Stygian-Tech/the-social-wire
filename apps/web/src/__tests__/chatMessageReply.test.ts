import { describe, expect, it } from "bun:test";
import { getChatMessageContent } from "@/lib/chatMessageReply";

const bytes = (text: string) => new TextEncoder().encode(text).length;
const parent = { $type: "chat.bsky.convo.defs#messageView", id: "parent", rev: "1", text: "Original message", sender: { did: "did:plc:abcdefghijklmnopqrstuvwx" }, sentAt: "2026-10-10T00:00:00Z" };
function link(text: string, value: string) {
  const start = text.indexOf(value);
  return { index: { byteStart: bytes(text.slice(0, start)), byteEnd: bytes(text.slice(0, start + value.length)) }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "https://example.test/" }] };
}

describe("chat reply content", () => {
  it("uses the native parent and preserves the complete body and parent facets", () => {
    const text = "> Literal quotation\n\n  Actual reply\n";
    const facets = [link(parent.text, "Original")];
    const result = getChatMessageContent({ text, replyTo: { ...parent, facets } });
    expect(result.body.text).toBe(text);
    expect(result.reply).toEqual({ text: parent.text, facets });
  });

  it("shows deleted, inaccessible, or invalid native parents without guessing from quoted text", () => {
    const text = "> Old quote\n\nReply";
    const { text: ignored, ...deleted } = parent;
    void ignored;
    expect(getChatMessageContent({ text, replyTo: { ...deleted, $type: "chat.bsky.convo.defs#deletedMessageView" } })).toEqual({ body: { text, facets: undefined }, replyUnavailable: "Message Deleted" });
    expect(getChatMessageContent({ text, replyTo: { $type: "chat.bsky.convo.defs#messageBeforeUserJoinedGroupView" } }).replyUnavailable).toBe("Message Sent Before You Joined");
    for (const replyTo of [null, {}, { ...parent, text: 42 }, { ...parent, sender: {} }]) expect(getChatMessageContent({ text, replyTo }).replyUnavailable).toBe("Reply Unavailable");
  });

  it("renders legacy quotes with preserved line breaks and untouched body whitespace", () => {
    expect(getChatMessageContent({ text: "> First line\n> \n> Last line\n\n  Reply\n" })).toEqual({ reply: { text: "First line\n\nLast line" }, body: { text: "  Reply\n" } });
    expect(getChatMessageContent({ text: "> First\r\n> Second\r\n\r\nReply\r\n" })).toEqual({ reply: { text: "First\r\nSecond" }, body: { text: "Reply\r\n" } });
  });

  it("retains ordinary text when there is no complete quote and reply", () => {
    for (const text of ["Replying", "> quoted", "> quoted\nNo separator", "> quoted\n\n", "> quoted\n\n  \n", "Intro\n> quoted\n\nReply"]) expect(getChatMessageContent({ text }).body.text).toBe(text);
  });

  it("projects UTF-8 facets in both quote and body after removing quote markers", () => {
    const text = "> 😀 Website\n> Another @person\n\n😮 Body link";
    const facets = [link(text, "Website"), { ...link(text, "@person"), features: [{ $type: "app.bsky.richtext.facet#mention", did: parent.sender.did }] }, link(text, "link")];
    const result = getChatMessageContent({ text, facets });
    expect(result.reply?.facets?.[0].index).toEqual({ byteStart: bytes("😀 "), byteEnd: bytes("😀 Website") });
    expect(result.reply?.facets?.[1].index).toEqual({ byteStart: bytes("😀 Website\nAnother "), byteEnd: bytes("😀 Website\nAnother @person") });
    expect(result.body.facets?.[0].index).toEqual({ byteStart: bytes("😮 Body "), byteEnd: bytes("😮 Body link") });
    expect(result.reply?.facets?.[1].features).toEqual(facets[1].features);
  });

  it("drops facets across removed markers and malformed UTF-8 boundaries", () => {
    const text = "> 😀 First\n> Second\n\nBody";
    const valid = link(text, "Body");
    const facets = [valid, { ...valid, index: { byteStart: 3, byteEnd: 5 } }, { ...valid, index: { byteStart: 2, byteEnd: bytes(text.slice(0, text.indexOf("Second") + 6)) } }];
    const result = getChatMessageContent({ text, facets });
    expect(result.reply?.facets).toBeUndefined();
    expect(result.body.facets).toHaveLength(1);
    expect(result.body.facets?.[0].index).toEqual({ byteStart: 0, byteEnd: 4 });
  });
});
