import { Agent, ChatBskyConvoDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";

export const LOCAL_CHAT_UNAVAILABLE = "This local ATProto stack has no chat service configured. Messages require a chat.bsky service; local accounts are never sent to the public Bluesky chat service.";

export function createAuthenticatedChatAgent(session: OAuthSession, viewerDid: string) {
  if (session.did !== viewerDid) throw new Error("Your account changed. Please reload Messages.");
  const chatDid = getAtprotoNetwork().chatServiceDid;
  if (!chatDid) throw new Error(LOCAL_CHAT_UNAVAILABLE);
  return new Agent(session).withProxy("bsky_chat", chatDid);
}

export async function getBlueskyConversations(args: { session: OAuthSession; viewerDid: string; cursor?: string; signal?: AbortSignal }) {
  return (await createAuthenticatedChatAgent(args.session, args.viewerDid).chat.bsky.convo.listConvos({ limit: 30, cursor: args.cursor }, { signal: args.signal })).data;
}

export async function getBlueskyMessages(args: { session: OAuthSession; viewerDid: string; convoId: string; cursor?: string; signal?: AbortSignal }) {
  if (!args.convoId) throw new Error("Select a conversation.");
  return (await createAuthenticatedChatAgent(args.session, args.viewerDid).chat.bsky.convo.getMessages({ convoId: args.convoId, limit: 50, cursor: args.cursor }, { signal: args.signal })).data;
}

export type ChatAction =
  | { kind: "start"; members: string[] }
  | { kind: "send"; convoId: string; text: string }
  | { kind: "read"; convoId: string; messageId?: string }
  | { kind: "delete"; convoId: string; messageId: string }
  | { kind: "mute" | "unmute"; convoId: string };

export async function performBlueskyChatAction(session: OAuthSession, viewerDid: string, action: ChatAction) {
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
    const members = [...new Set(resolved)];
    return (await convo.getConvoForMembers({ members })).data;
  }
  if (!action.convoId) throw new Error("Select a conversation.");
  switch (action.kind) {
    case "send": {
      const message = { text: action.text.trim() };
      if (!message.text || !ChatBskyConvoDefs.validateMessageInput(message).success) throw new Error("Enter a message of at most 1,000 characters.");
      return (await convo.sendMessage({ convoId: action.convoId, message })).data;
    }
    case "read": return (await convo.updateRead({ convoId: action.convoId, messageId: action.messageId })).data;
    case "delete":
      if (!action.messageId) throw new Error("Select a message.");
      return (await convo.deleteMessageForSelf({ convoId: action.convoId, messageId: action.messageId })).data;
    case "mute": return (await convo.muteConvo({ convoId: action.convoId })).data;
    case "unmute": return (await convo.unmuteConvo({ convoId: action.convoId })).data;
  }
}
