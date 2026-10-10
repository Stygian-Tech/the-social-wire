"use client";

import { ChatBskyConvoDefs, type ChatBskyConvoGetMessages } from "@atproto/api";
import { Button } from "@/components/ui/button";

type Message = ChatBskyConvoGetMessages.OutputSchema["messages"][number];
export function SocialChatMessage({ message, viewerDid, pending, onDelete }: { message: Message; viewerDid: string; pending: boolean; onDelete: (id: string) => void }) {
  if (ChatBskyConvoDefs.isDeletedMessageView(message)) return <p className="py-2 text-sm italic text-muted-foreground">Message Deleted</p>;
  if (!ChatBskyConvoDefs.isMessageView(message)) return <p className="py-2 text-sm text-muted-foreground">Conversation Updated</p>;
  const own = message.sender.did === viewerDid;
  return <article className={`flex flex-col gap-1 rounded-lg p-3 ${own ? "ml-8 bg-primary/10" : "mr-8 bg-muted"}`}>
    <p className="whitespace-pre-wrap break-words text-sm">{message.text}</p>
    <div className="flex items-center justify-between gap-2 text-xs text-muted-foreground"><time dateTime={message.sentAt}>{new Date(message.sentAt).toLocaleString()}</time><Button variant="ghost" size="sm" disabled={pending} onClick={() => onDelete(message.id)}>Delete For Me</Button></div>
  </article>;
}
