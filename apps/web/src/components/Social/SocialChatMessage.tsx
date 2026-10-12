"use client";

import { useState } from "react";
import { AppBskyEmbedRecord, ChatBskyConvoDefs, type ChatBskyConvoGetMessages, type ModerationOpts } from "@atproto/api";
import { Flag, MoreHorizontal, Reply, Trash2 } from "lucide-react";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { useSocialPostNavigation } from "@/hooks/useSocialPostNavigation";
import { getChatMessageContent } from "@/lib/chatMessageReply";
import { SocialChatRichText } from "./SocialChatRichText";
import { SocialChatLinkPreview } from "./SocialChatLinkPreview";
import { SocialChatPostPreview } from "./SocialChatPostPreview";
import { SocialPostEmbed } from "./SocialPostEmbed";

export const CHAT_REACTIONS = ["❤️", "👍", "😂", "😮", "😢", "🙏"] as const;
type Message = ChatBskyConvoGetMessages.OutputSchema["messages"][number];
export function SocialChatMessage({ message, viewerDid, pending, moderation, onDelete, onReply, onReaction, onReport, contentHidden = false, noOverride = false, suppressPreviews = false, replyHidden = false, canInteract = true }: { message: Message; viewerDid: string; pending: boolean; moderation?: ModerationOpts; onDelete: (id: string) => void; onReply: (message: { id: string; text: string }) => void; onReaction: (messageId: string, value: string, remove: boolean) => void; onReport?: (messageId: string, senderDid: string) => void; contentHidden?: boolean; noOverride?: boolean; suppressPreviews?: boolean; replyHidden?: boolean; canInteract?: boolean }) {
  const navigation = useSocialPostNavigation();
  const [revealed, setRevealed] = useState(false);
  const hidden = contentHidden && (!revealed || noOverride);
  if (ChatBskyConvoDefs.isDeletedMessageView(message)) return <p className="py-1 text-xs italic text-muted-foreground">Message Deleted</p>;
  if (!ChatBskyConvoDefs.isMessageView(message)) return <p className="py-1 text-xs text-muted-foreground">Conversation Updated</p>;
  const content = getChatMessageContent(message);
  const own = message.sender.did === viewerDid;
  const reactions = [...new Set(message.reactions?.map(reaction => reaction.value))];
  const reacted = (value: string) => !!message.reactions?.some(reaction => reaction.value === value && reaction.sender.did === viewerDid);
  const stamp = new Date(message.sentAt);
  return <div className={`flex ${own ? "justify-end" : "justify-start"}`}><div className={`flex min-w-0 max-w-[85%] flex-col ${own ? "items-end" : "items-start"}`}><article aria-label={own ? "Sent Message" : "Received Message"} className={`flex w-fit min-w-0 max-w-full flex-col gap-1 rounded-xl px-3 py-2 ${own ? "bg-primary/10" : "bg-muted"}`}>
    {hidden ? <div className="space-y-2"><p className="text-sm text-muted-foreground">Message Hidden by Your Moderation Settings</p>{!noOverride ? <button type="button" className="text-sm underline" onClick={() => setRevealed(true)}>Show Message</button> : null}</div> : <>
    {content.reply || content.replyUnavailable ? <blockquote aria-label="Replied-To Message" className="mb-1 min-w-0 rounded-lg bg-background/40 px-2 py-1.5 text-muted-foreground"><span className="mb-1 block text-[10px] font-medium">Replying To</span>{replyHidden ? <p className="text-xs">Message Hidden by Your Moderation Settings</p> : content.reply ? <SocialChatRichText message={content.reply} /> : <p className="text-xs">{content.replyUnavailable}</p>}</blockquote> : null}
    <SocialChatRichText message={content.body} />
    {!suppressPreviews && !message.embed ? <SocialChatPostPreview text={content.body.text} moderation={moderation} /> : null}
    {!suppressPreviews && !message.embed ? <SocialChatLinkPreview message={content.body} /> : null}
    {!suppressPreviews && message.embed ? AppBskyEmbedRecord.isView(message.embed) && moderation?.userDid === viewerDid ? <div className="mt-1"><SocialPostEmbed embed={message.embed} moderation={moderation} onOpenPost={post => navigation.openPost(post.uri)} /></div> : <p className="text-xs text-muted-foreground">Attachment unavailable.</p> : null}
  </>}
  </article>
    {!hidden && reactions.length ? <div aria-label="Message Reactions" className={`relative z-10 -mt-1 flex max-w-full flex-wrap gap-1 px-2 ${own ? "justify-end" : "justify-start"}`}>{reactions.map(value => <button key={value} type="button" disabled={pending || !canInteract} aria-label={`${reacted(value) ? "Remove" : "Add"} Reaction ${value}`} aria-pressed={reacted(value)} onClick={() => onReaction(message.id, value, reacted(value))} className="rounded-full border bg-card px-2 py-0.5 shadow-sm text-xs hover:bg-accent">{value} {message.reactions?.filter(reaction => reaction.value === value).length}</button>)}</div> : null}
    <div className="flex items-center justify-end gap-2 text-[10px] text-muted-foreground">{!Number.isNaN(stamp.getTime()) ? <time dateTime={message.sentAt} title={stamp.toLocaleString()}>{stamp.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</time> : null}
      <DropdownMenu><DropdownMenuTrigger disabled={pending} aria-label="Message Actions" className="flex min-h-7 min-w-7 items-center justify-center rounded hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring"><MoreHorizontal className="size-3.5" /></DropdownMenuTrigger><DropdownMenuContent align="end">
        {!hidden ? <DropdownMenuItem disabled={!canInteract} onClick={() => onReply({ id: message.id, text: content.body.text })}><Reply className="size-4" />Reply</DropdownMenuItem> : null}
        {!hidden && CHAT_REACTIONS.map(value => <DropdownMenuItem key={value} disabled={!canInteract} onClick={() => onReaction(message.id, value, reacted(value))}>{reacted(value) ? "Remove" : "React"} {value}</DropdownMenuItem>)}
        {!own && onReport ? <DropdownMenuItem onClick={() => onReport(message.id, message.sender.did)}><Flag className="size-4" />Report Message</DropdownMenuItem> : null}
        <DropdownMenuItem variant="destructive" onClick={() => onDelete(message.id)}><Trash2 className="size-4" />Delete For Me</DropdownMenuItem>
      </DropdownMenuContent></DropdownMenu>
    </div>
  </div></div>;
}
