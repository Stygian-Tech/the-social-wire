import { AppBskyRichtextFacet, ChatBskyConvoDefs } from "@atproto/api";

type ChatText = Pick<ChatBskyConvoDefs.MessageView, "text" | "facets">;
type ChatContent = { body: ChatText; reply?: ChatText; replyUnavailable?: string };
type RetainedText = { start: number; end: number; outputStart: number };
const encoder = new TextEncoder();
const bytes = (text: string) => encoder.encode(text).length;

function boundaries(text: string) {
  const result = new Set([0]);
  let offset = 0;
  for (const character of text) { offset += bytes(character); result.add(offset); }
  return result;
}

function projectFacets(source: ChatText, text: string, retained: RetainedText[]): ChatText {
  const sourceBoundaries = boundaries(source.text);
  const facets = source.facets?.flatMap(facet => {
    if (!AppBskyRichtextFacet.validateMain(facet).success) return [];
    const { byteStart, byteEnd } = facet.index;
    if (byteEnd <= byteStart || !sourceBoundaries.has(byteStart) || !sourceBoundaries.has(byteEnd)) return [];
    const range = retained.find(value => byteStart >= value.start && byteEnd <= value.end);
    if (!range) return [];
    return [{ ...facet, index: { byteStart: range.outputStart + byteStart - range.start, byteEnd: range.outputStart + byteEnd - range.start } }];
  });
  return { text, ...(facets?.length ? { facets } : {}) };
}

/** Older Social Wire replies contain a leading text quote rather than a native reply reference. */
function legacyReply(message: ChatText): ChatContent | undefined {
  let cursor = 0;
  let quote = "";
  const ranges: RetainedText[] = [];
  while (message.text.startsWith("> ", cursor)) {
    const match = /^> ([^\r\n]*)(\r?\n|$)/.exec(message.text.slice(cursor));
    if (!match || !match[2]) return undefined;
    const textStart = cursor + 2;
    const textEnd = textStart + match[1].length;
    ranges.push({ start: bytes(message.text.slice(0, textStart)), end: bytes(message.text.slice(0, textEnd)), outputStart: bytes(quote) });
    quote += match[1];
    cursor += match[0].length;
    if (message.text.startsWith("> ", cursor)) quote += match[2];
  }
  const separator = /^(\r?\n)/.exec(message.text.slice(cursor));
  if (!ranges.length || !separator) return undefined;
  cursor += separator[0].length;
  const body = message.text.slice(cursor);
  if (!body.trim()) return undefined;
  return {
    reply: projectFacets(message, quote, ranges),
    body: projectFacets(message, body, [{ start: bytes(message.text.slice(0, cursor)), end: bytes(message.text), outputStart: 0 }]),
  };
}

export function getChatMessageContent(message: ChatText & { replyTo?: unknown }): ChatContent {
  const body = { text: message.text, facets: message.facets };
  const parent = message.replyTo;
  if (parent !== undefined) {
    if (ChatBskyConvoDefs.isMessageView(parent)) {
      const result = ChatBskyConvoDefs.validateMessageView(parent);
      if (result.success) return { body, reply: { text: result.value.text, facets: result.value.facets } };
    }
    if (ChatBskyConvoDefs.isDeletedMessageView(parent) && ChatBskyConvoDefs.validateDeletedMessageView(parent).success) return { body, replyUnavailable: "Message Deleted" };
    if (parent && typeof parent === "object" && "$type" in parent && parent.$type === "chat.bsky.convo.defs#messageBeforeUserJoinedGroupView") return { body, replyUnavailable: "Message Sent Before You Joined" };
    return { body, replyUnavailable: "Reply Unavailable" };
  }
  return legacyReply(message) ?? { body };
}
