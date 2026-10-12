import { ChatBskyConvoDefs } from "@atproto/api";

export function chatConversationName(convo: ChatBskyConvoDefs.ConvoView, memberNames: string[]): string {
  const group = ChatBskyConvoDefs.isGroupConvo(convo.kind) ? convo.kind : undefined;
  return group?.name.trim() || memberNames.join(", ") || "Conversation";
}
