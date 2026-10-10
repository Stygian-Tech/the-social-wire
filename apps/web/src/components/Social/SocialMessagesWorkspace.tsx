"use client";

import { useState } from "react";
import { ChatBskyConvoDefs } from "@atproto/api";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { useBlueskyMessages } from "@/hooks/useBlueskyMessages";
import { LOCAL_CHAT_UNAVAILABLE, type ChatAction } from "@/lib/blueskyChatClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialChatMessage } from "./SocialChatMessage";

export function SocialMessagesWorkspace({ viewerDid, draft = "" }: { viewerDid: string; draft?: string }) {
  const [convoId, setConvoId] = useState<string>();
  const [recipient, setRecipient] = useState("");
  const [text, setText] = useState(draft);
  const [actionError, setActionError] = useState<string>();
  const [deleteId, setDeleteId] = useState<string>();
  const chat = useBlueskyMessages(convoId);
  const convos = [...new Map((chat.conversations.data?.pages.flatMap(page => page.convos) ?? []).map(convo => [convo.id, convo])).values()];
  const active = convos.find(convo => convo.id === convoId);
  const messages = [...new Map((chat.messages.data?.pages.flatMap(page => page.messages) ?? []).filter(message => "id" in message).map(message => [String(message.id), message])).values()].reverse();
  const error = actionError ?? (chat.conversations.isError ? socialErrorMessage(chat.conversations.error) : chat.messages.isError ? socialErrorMessage(chat.messages.error) : undefined);
  async function perform(action: ChatAction) {
    setActionError(undefined);
    try {
      const result = await chat.perform(action);
      if (action.kind === "start" && "convo" in result) { setConvoId(result.convo.id); setRecipient(""); }
      if (action.kind === "send") setText("");
      if (action.kind === "delete") setDeleteId(undefined);
    } catch (failure) { setActionError(socialErrorMessage(failure)); }
  }
  return <div className="flex min-h-0 flex-1 flex-col">
    <FeedHeader title="Messages" subtitle="Private Conversations" />
    {!chat.available ? <section role="status" className="space-y-2 p-6"><h2 className="font-semibold">Messages Unavailable Locally</h2><p className="text-sm text-muted-foreground">{LOCAL_CHAT_UNAVAILABLE}</p></section> : <div className="min-h-0 flex-1 overflow-y-auto p-3 sm:p-4">
      {error ? <section role="alert" className="mb-4 rounded-lg border p-3"><p className="text-sm">{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" onClick={() => { void chat.conversations.refetch(); if (convoId) void chat.messages.refetch(); }}>Retry</Button>}</section> : null}
      <div className="mx-auto grid max-w-4xl gap-4 md:grid-cols-[240px_minmax(0,1fr)]">
        <aside className="space-y-3" aria-label="Conversations">
          <form className="flex flex-col gap-2" onSubmit={event => { event.preventDefault(); void perform({ kind: "start", members: [recipient.trim()] }); }}><label className="text-sm" htmlFor="chat-recipient">Recipient Handle Or DID</label><input id="chat-recipient" disabled={chat.action.isPending} value={recipient} onChange={event => setRecipient(event.target.value)} className="min-w-0 rounded-md border bg-background px-3 py-2 text-sm" placeholder="alice.bsky.social" /><Button type="submit" disabled={!recipient.trim() || chat.action.isPending}>New Conversation</Button></form>
          {chat.conversations.isPending ? <p role="status" className="text-sm text-muted-foreground">Loading Conversations…</p> : !convos.length && !chat.conversations.isError ? <p className="text-sm text-muted-foreground">No Conversations Yet.</p> : null}
          {convos.map(convo => <Button key={convo.id} variant={convo.id === convoId ? "secondary" : "ghost"} className="h-auto w-full justify-start whitespace-normal text-left" disabled={chat.action.isPending} onClick={() => { setConvoId(convo.id); setActionError(undefined); setDeleteId(undefined); }}><span className="min-w-0"><span className="block break-words">{convo.members.filter(member => member.did !== viewerDid).map(member => member.displayName || member.handle).join(", ") || "Conversation"}</span>{convo.unreadCount > 0 ? <span className="block text-xs">{convo.unreadCount} Unread</span> : null}</span></Button>)}
          {chat.conversations.hasNextPage ? <Button variant="outline" disabled={chat.conversations.isFetchingNextPage} onClick={() => { void chat.conversations.fetchNextPage(); }}>More Conversations</Button> : null}
        </aside>
        <section className="min-w-0 space-y-3" aria-label="Messages">
          {!convoId ? <p className="py-8 text-center text-sm text-muted-foreground">Select a Conversation.</p> : <>
            <div className="flex flex-wrap gap-2"><Button variant="outline" size="sm" disabled={chat.action.isPending} onClick={() => { void perform({ kind: active?.muted ? "unmute" : "mute", convoId }); }}>{active?.muted ? "Unmute" : "Mute"}</Button><Button variant="outline" size="sm" disabled={chat.action.isPending} onClick={() => { void perform({ kind: "read", convoId }); }}>Mark As Read</Button></div>
            {chat.messages.hasNextPage ? <Button variant="outline" disabled={chat.messages.isFetchingNextPage} onClick={() => { void chat.messages.fetchNextPage(); }}>Older Messages</Button> : null}
            {chat.messages.isPending ? <p role="status">Loading Messages…</p> : messages.length ? messages.map(message => <SocialChatMessage key={String(message.id)} message={message} viewerDid={viewerDid} pending={chat.action.isPending} onDelete={setDeleteId} />) : !chat.messages.isError ? <p className="text-sm text-muted-foreground">No Messages Yet.</p> : null}
            {deleteId ? <div role="alert" className="space-y-2 rounded-lg border p-3"><p className="text-sm">Delete This Message For You? Other Participants Keep Their Copy.</p><div className="flex gap-2"><Button variant="destructive" disabled={chat.action.isPending} onClick={() => { void perform({ kind: "delete", convoId, messageId: deleteId }); }}>Delete For Me</Button><Button variant="outline" onClick={() => setDeleteId(undefined)}>Cancel</Button></div></div> : null}
            <form className="flex flex-col gap-2" onSubmit={event => { event.preventDefault(); void perform({ kind: "send", convoId, text }); }}><label htmlFor="chat-message" className="text-sm">Message</label><textarea id="chat-message" disabled={chat.action.isPending} value={text} onChange={event => setText(event.target.value)} rows={3} className="w-full rounded-md border bg-background px-3 py-2 text-sm" /><Button type="submit" disabled={chat.action.isPending || !text.trim() || !ChatBskyConvoDefs.validateMessageInput({ text: text.trim() }).success}>Send Message</Button></form>
          </>}
        </section>
      </div>
    </div>}
  </div>;
}
