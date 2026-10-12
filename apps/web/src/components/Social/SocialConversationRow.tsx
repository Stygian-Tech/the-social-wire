"use client";

import type { ChatBskyConvoDefs } from "@atproto/api";
import { Bell, BellOff, CheckCheck, MoreHorizontal, Trash2 } from "lucide-react";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { ContextMenu, ContextMenuContent, ContextMenuGroup, ContextMenuItem, ContextMenuSeparator, ContextMenuTrigger } from "@/components/ui/context-menu";
import { DropdownMenu, DropdownMenuContent, DropdownMenuGroup, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { chatConversationPreview } from "@/lib/chatConversationPreview";
import { cn } from "@/lib/utils";

export function SocialConversationRow({ convo, viewerDid, name, avatar, selected, pending, previewHidden, onSelect, onAction }: {
  convo: ChatBskyConvoDefs.ConvoView;
  viewerDid: string;
  name: string;
  avatar?: string;
  selected: boolean;
  pending: boolean;
  previewHidden: boolean;
  onSelect: () => void;
  onAction: (kind: "read" | "mute" | "unmute" | "leave") => void;
}) {
  const actions = [
    { kind: "read" as const, label: "Mark As Read", icon: CheckCheck, disabled: pending || convo.unreadCount === 0 },
    { kind: convo.muted ? "unmute" as const : "mute" as const, label: convo.muted ? "Unmute Conversation" : "Mute Conversation", icon: convo.muted ? Bell : BellOff, disabled: pending },
  ];
  return <ContextMenu>
    <ContextMenuTrigger render={<div />} className={cn("flex w-full min-w-0 items-center gap-1 rounded-xl transition-colors", selected ? "bg-secondary" : !pending && "hover:bg-muted dark:hover:bg-muted/50")}>
      <Button variant="ghost" className="h-auto min-w-0 flex-1 justify-start gap-2 whitespace-normal py-3 text-left hover:bg-transparent dark:hover:bg-transparent" disabled={pending} aria-current={selected ? "true" : undefined} onClick={onSelect}>
        <Avatar src={avatar} alt="" size={32} className="shrink-0" />
        <span className="flex min-w-0 flex-1 flex-col gap-1">
          <span className="flex min-w-0 items-start gap-2">
            <span className="min-w-0 flex-1 break-words text-sm [overflow-wrap:anywhere]">{name}</span>
            {convo.muted ? <span className="shrink-0 text-muted-foreground" role="img" aria-label="Muted Conversation"><BellOff className="size-3.5" aria-hidden="true" /></span> : null}
            {convo.unreadCount > 0 ? <span className="shrink-0 rounded-full bg-primary px-1.5 py-0.5 text-xs text-primary-foreground" aria-label={`${convo.unreadCount} Unread ${convo.unreadCount === 1 ? "Message" : "Messages"}`}>{convo.unreadCount}</span> : null}
          </span>
          <span className="line-clamp-2 break-words text-xs font-normal text-muted-foreground [overflow-wrap:anywhere]">{chatConversationPreview(convo.lastMessage, viewerDid, previewHidden)}</span>
        </span>
      </Button>
      <DropdownMenu>
        <DropdownMenuTrigger render={<Button variant="ghost" size="icon-xs" />} className="mr-1 shrink-0" disabled={pending} aria-label={`More Actions For ${name}`}><MoreHorizontal aria-hidden="true" /></DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-max min-w-56 whitespace-nowrap">
          <DropdownMenuGroup>{actions.map(action => <DropdownMenuItem key={action.kind} disabled={action.disabled} onClick={() => onAction(action.kind)}><action.icon aria-hidden="true" />{action.label}</DropdownMenuItem>)}</DropdownMenuGroup>
          <DropdownMenuSeparator />
          <DropdownMenuGroup><DropdownMenuItem variant="destructive" disabled={pending} onClick={() => onAction("leave")}><Trash2 aria-hidden="true" />Delete Conversation</DropdownMenuItem></DropdownMenuGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    </ContextMenuTrigger>
    <ContextMenuContent className="w-max min-w-56 whitespace-nowrap">
      <ContextMenuGroup>{actions.map(action => <ContextMenuItem key={action.kind} disabled={action.disabled} onClick={() => onAction(action.kind)}><action.icon aria-hidden="true" />{action.label}</ContextMenuItem>)}</ContextMenuGroup>
      <ContextMenuSeparator />
      <ContextMenuGroup><ContextMenuItem variant="destructive" disabled={pending} onClick={() => onAction("leave")}><Trash2 aria-hidden="true" />Delete Conversation</ContextMenuItem></ContextMenuGroup>
    </ContextMenuContent>
  </ContextMenu>;
}
