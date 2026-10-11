import { Agent, ChatBskyConvoDefs, RichText } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";

export const LOCAL_CHAT_UNAVAILABLE = "This local ATProto stack has no chat service configured. Messages require a chat.bsky service; local accounts are never sent to the public Bluesky chat service.";

export function createAuthenticatedChatAgent(session: OAuthSession, viewerDid: string) {
  if (session.did !== viewerDid) throw new Error("Your account changed. Please reload Messages.");
  const chatDid = getAtprotoNetwork().chatServiceDid;
  if (!chatDid) throw new Error(LOCAL_CHAT_UNAVAILABLE);
  return new Agent(session).withProxy("bsky_chat", chatDid);
}

export async function getBlueskyConversations(args: { session: OAuthSession; viewerDid: string; cursor?: string; readState?: "unread"; signal?: AbortSignal }) {
  return (await createAuthenticatedChatAgent(args.session, args.viewerDid).chat.bsky.convo.listConvos({ limit: 30, cursor: args.cursor, readState: args.readState }, { signal: args.signal })).data;
}

// listConvos has per-conversation counts, but no aggregate. Complete every unread
// page before publishing a badge; an incomplete page must never appear as a total.
export async function getBlueskyMessageUnread(args: { session: OAuthSession; viewerDid: string; signal?: AbortSignal }) {
  const counts = new Map<string, number>();
  const cursors = new Set<string>();
  let cursor: string | undefined;
  do {
    args.signal?.throwIfAborted();
    const page = await getBlueskyConversations({ ...args, cursor, readState: "unread" });
    for (const convo of page.convos) {
      if (!counts.has(convo.id)) counts.set(convo.id, Math.max(0, convo.unreadCount));
    }
    cursor = page.cursor || undefined;
    if (cursor && cursors.has(cursor)) throw new Error("Unread message pagination did not complete.");
    if (cursor) cursors.add(cursor);
  } while (cursor);
  return [...counts.values()].reduce((total, count) => total + count, 0);
}

export async function getBlueskyMessages(args: { session: OAuthSession; viewerDid: string; convoId: string; cursor?: string; signal?: AbortSignal }) {
  if (!args.convoId) throw new Error("Select a conversation.");
  return (await createAuthenticatedChatAgent(args.session, args.viewerDid).chat.bsky.convo.getMessages({ convoId: args.convoId, limit: 50, cursor: args.cursor }, { signal: args.signal })).data;
}

export type ChatAction =
  | { kind: "start"; members: string[] }
  | { kind: "send"; convoId: string; text: string; replyTo?: string }
  | { kind: "read"; convoId: string; messageId?: string }
  | { kind: "delete"; convoId: string; messageId: string }
  | { kind: "addReaction" | "removeReaction"; convoId: string; messageId: string; value: string }
  | { kind: "mute" | "unmute"; convoId: string };

export async function performBlueskyChatAction(session: OAuthSession, viewerDid: string, action: ChatAction, assertViewer?: () => void) {
  assertViewer?.();
  const convo = createAuthenticatedChatAgent(session, viewerDid).chat.bsky.convo;
  if (action.kind === "start") {
    const didPattern = /^did:(plc:[a-z2-7]{24}|web:[^\s/?#]+)$/;
    if (!action.members.length) throw new Error("Enter a valid recipient handle or DID.");
    const resolved = await Promise.all(action.members.map(async input => {
      const recipient = input.trim().replace(/^@/, "");
      if (didPattern.test(recipient)) return recipient;
      if (!/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/i.test(recipient)) throw new Error("Enter a valid recipient handle or DID.");
      // Handle resolution is public on the configured network, never an OAuth token recipient.
      const response = await new Agent(getAtprotoNetwork().handleResolver).com.atproto.identity.resolveHandle({ handle: recipient });
      if (!didPattern.test(response.data.did)) throw new Error("The recipient handle could not be resolved.");
      return response.data.did;
    }));
    assertViewer?.();
    const members = [...new Set(resolved)];
    return (await convo.getConvoForMembers({ members })).data;
  }
  if (!action.convoId) throw new Error("Select a conversation.");
  switch (action.kind) {
    case "send": {
      if (action.replyTo !== undefined && !action.replyTo.trim()) throw new Error("Select a message to reply to.");
      // The current chat schema supports replies; the installed SDK types lag this field.
      const message = { text: action.text.trim(), ...(action.replyTo ? { replyTo: { messageId: action.replyTo } } : {}) };
      if (!message.text || !ChatBskyConvoDefs.validateMessageInput(message).success) throw new Error("Enter a message of at most 1,000 characters.");
      const richText = new RichText({ text: message.text });
      if (/@[a-z0-9-]+(?:\.[a-z0-9-]+)+|https:\/\//i.test(message.text)) {
        await richText.detectFacets(createAuthenticatedAppViewAgent(session));
        assertViewer?.();
      }
      return (await convo.sendMessage({ convoId: action.convoId, message: { ...message, ...(richText.facets?.length ? { facets: richText.facets } : {}) } })).data;
    }
    case "read": return (await convo.updateRead({ convoId: action.convoId, messageId: action.messageId })).data;
    case "delete":
      if (!action.messageId) throw new Error("Select a message.");
      return (await convo.deleteMessageForSelf({ convoId: action.convoId, messageId: action.messageId })).data;
    case "addReaction":
    case "removeReaction":
      if (!action.messageId || !["❤️", "👍", "😂", "😮", "😢", "🙏"].includes(action.value)) throw new Error("Select a valid message reaction.");
      return (await convo[action.kind]({ convoId: action.convoId, messageId: action.messageId, value: action.value })).data;
    case "mute": return (await convo.muteConvo({ convoId: action.convoId })).data;
    case "unmute": return (await convo.unmuteConvo({ convoId: action.convoId })).data;
  }
}
