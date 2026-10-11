import { ChatBskyConvoDefs } from "@atproto/api";

export function chatConversationPreview(message: ChatBskyConvoDefs.ConvoView["lastMessage"], viewerDid: string, hidden = false): string {
  if (hidden) return "Message Hidden";
  if (!message) return "No Messages Yet";
  if (ChatBskyConvoDefs.isDeletedMessageView(message)) return "Message Deleted";
  if (!ChatBskyConvoDefs.isMessageView(message)) return "Message Unavailable";
  const text = message.text.replace(/\s+/g, " ").trim();
  const preview = text || (message.embed ? "Shared Post" : "Message");
  return message.sender.did === viewerDid ? `You: ${preview}` : preview;
}
