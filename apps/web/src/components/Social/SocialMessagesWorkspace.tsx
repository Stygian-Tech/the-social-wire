"use client";

import { Fragment, useEffect, useLayoutEffect, useRef, useState } from "react";
import { ChatBskyConvoDefs, moderateProfile, type ChatBskyActorDefs } from "@atproto/api";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { Avatar } from "@/components/shared/Avatar";
import { floatingSidebarClassName } from "@/components/shared/floatingSidebarStyles";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { socialHttpsUrl } from "./socialUrls";
import { SocialMessageInput } from "./SocialMessageInput";
import { SocialNewConversationDialog } from "./SocialNewConversationDialog";
import { useBlueskyMessages } from "@/hooks/useBlueskyMessages";
import { LOCAL_CHAT_UNAVAILABLE, type ChatAction } from "@/lib/blueskyChatClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialChatMessage } from "./SocialChatMessage";
import { chatMessageDays } from "@/lib/chatMessageDays";

export function SocialMessagesWorkspace({ viewerDid, draft = "" }: { viewerDid: string; draft?: string }) {
  const [convoId, setConvoId] = useState<string>();
  const { getOAuthSession } = useAuth();
  const lock = useRef(false);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const [reply, setReply] = useState<{ id: string; text: string }>();
  const [text, setText] = useState(draft);
  const [actionError, setActionError] = useState<string>();
  const [deleteId, setDeleteId] = useState<string>();
  const chat = useBlueskyMessages(convoId);
  const catalog = useBlueskySocialCatalog({ enabled: chat.available });
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === viewerDid ? catalog.data?.moderation : undefined;
  const outgoing = text;
  function assertViewer() { if (!mounted.current || getOAuthSession()?.did !== viewerDid) throw new Error("Your account changed. Please reload Messages."); }
  const convos = [...new Map((chat.conversations.data?.pages.flatMap(page => page.convos) ?? []).map(convo => [convo.id, convo])).values()];
  const active = convos.find(convo => convo.id === convoId);
  function contact(member: ChatBskyActorDefs.ProfileViewBasic) {
    const safety = moderation ? moderateProfile({ ...member, $type: "app.bsky.actor.defs#profileViewBasic" }, moderation) : undefined;
    const hidden = (context: "profileList" | "displayName" | "avatar") => { const ui = safety?.ui(context); return !ui || ui.filter || ui.blur || ui.noOverride; };
    return { name: hidden("profileList") || hidden("displayName") ? "Account" : member.displayName || member.handle, avatar: hidden("profileList") || hidden("avatar") ? undefined : socialHttpsUrl(member.avatar) };
  }
  const activeMembers = active?.members.filter(member => member.did !== viewerDid) ?? [];
  const headerContact = activeMembers[0] ?? active?.members.find(member => member.did === viewerDid);
  const firstContact = headerContact ? contact(headerContact) : undefined;
  const header = firstContact ? { ...firstContact, name: activeMembers.length > 1 ? activeMembers.map(contact).map(member => member.name).join(", ") : firstContact.name } : undefined;
  const messages = [...new Map((chat.messages.data?.pages.flatMap(page => page.messages) ?? []).filter(message => "id" in message).map(message => [String(message.id), message])).values()].reverse();
  const messageDays = chatMessageDays(messages);
  const viewport = useRef<HTMLDivElement>(null);
  const scrollState = useRef<{ id?: string; top: number; count: number; atBottom: boolean }>({ top: 0, count: 0, atBottom: true });
  const pagination = useRef(false);
  const touch = useRef<{ x: number; y: number } | undefined>(undefined);
  const anchor = useRef<{ id: string; height: number; top: number } | undefined>(undefined);
  const currentConvo = useRef(convoId);

  useLayoutEffect(() => {
    currentConvo.current = convoId;
    const element = viewport.current;
    if (!element) return;
    const saved = anchor.current;
    if (saved && saved.id !== convoId) anchor.current = undefined;
    if (saved && saved.id === convoId) { element.scrollTop = saved.top + element.scrollHeight - saved.height; anchor.current = undefined; }
    else if (scrollState.current.id !== convoId || scrollState.current.count === 0 || scrollState.current.atBottom) element.scrollTop = element.scrollHeight;
    scrollState.current = { id: convoId, top: element.scrollTop, count: messages.length, atBottom: element.scrollHeight - element.scrollTop - element.clientHeight <= 32 };
  }, [convoId, messages.length, chat.messages.data?.pages.length]);
  async function loadOlder() {
    const element = viewport.current;
    if (!element || !convoId || pagination.current || !chat.messages.hasNextPage || chat.messages.isFetchingNextPage || chat.messages.isPending || !messages.length) return;
    const id = convoId;
    pagination.current = true; anchor.current = { id, height: element.scrollHeight, top: element.scrollTop };
    try { const result = await chat.messages.fetchNextPage(); if (result.isError && currentConvo.current === id) anchor.current = undefined; }
    catch { if (currentConvo.current === id) anchor.current = undefined; }
    finally { pagination.current = false; }
  }
  const error = actionError ?? (chat.conversations.isError ? socialErrorMessage(chat.conversations.error) : chat.messages.isError ? socialErrorMessage(chat.messages.error) : undefined);
  async function perform(action: ChatAction) {
    if (lock.current) return;
    lock.current = true; setActionError(undefined);
    try {
      assertViewer();
      const result = await chat.perform(action);
      assertViewer();
      if (action.kind === "start" && "convo" in result) setConvoId(result.convo.id);
      if (action.kind === "send") { setText(""); setReply(undefined); }
      if (action.kind === "delete") setDeleteId(undefined);
    } catch (failure) { if (mounted.current) setActionError(socialErrorMessage(failure)); }
    finally { lock.current = false; }
  }
  return <div className="flex min-h-0 flex-1 flex-col">
    <FeedHeader title={header?.name ?? "Messages"} subtitle={activeMembers.length > 1 ? `${activeMembers.length + 1} Participants` : active ? "Private Conversation" : "Private Conversations"} leading={header ? <Avatar src={header.avatar} alt="" size={36} className="shrink-0" /> : undefined} />
    {!chat.available ? <section role="status" className="space-y-2 p-6"><h2 className="font-semibold">Messages Unavailable Locally</h2><p className="text-sm text-muted-foreground">{LOCAL_CHAT_UNAVAILABLE}</p></section> : <div className="flex min-h-0 flex-1 flex-col overflow-hidden p-3 sm:p-4">
      {error ? <section role="alert" className="mb-4 rounded-lg border p-3"><p className="text-sm">{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" onClick={() => { void chat.conversations.refetch(); if (convoId) void chat.messages.refetch(); }}>Retry</Button>}</section> : null}
      <div className="grid min-h-0 w-full flex-1 grid-rows-[auto_minmax(0,1fr)] gap-4 md:grid-cols-[minmax(0,1fr)_240px] md:grid-rows-[minmax(0,1fr)]">
        <aside className={`${floatingSidebarClassName} max-h-40 w-full min-h-0 space-y-3 overflow-y-auto overscroll-contain md:col-start-2 md:row-start-1 md:max-h-full`} aria-label="Conversations">
          <h2 className="px-2 text-sm font-semibold">Conversations</h2>
          <SocialNewConversationDialog initialMessage={text} disabled={chat.action.isPending} perform={chat.perform} assertViewer={assertViewer} onSent={id => { setConvoId(id); setText(""); setReply(undefined); setActionError(undefined); }} />
          {chat.conversations.isPending ? <p role="status" className="text-sm text-muted-foreground">Loading Conversations…</p> : !convos.length && !chat.conversations.isError ? <p className="text-sm text-muted-foreground">No Conversations Yet.</p> : null}
          {convos.map(convo => {
            const contacts = convo.members.filter(member => member.did !== viewerDid);
            const safeContacts = contacts.map(contact);
            const name = safeContacts.map(contact => contact.name).join(", ") || "Conversation";
            return <Button key={convo.id} variant={convo.id === convoId ? "secondary" : "ghost"} className="h-auto w-full justify-start gap-2 whitespace-normal py-2 text-left" disabled={chat.action.isPending} onClick={() => { setConvoId(convo.id); setActionError(undefined); setDeleteId(undefined); setReply(undefined); }}><Avatar src={safeContacts[0]?.avatar} alt="" size={32} className="shrink-0" /><span className="min-w-0"><span className="block break-words text-sm">{name}</span>{convo.unreadCount > 0 ? <span className="block text-xs text-muted-foreground">{convo.unreadCount} Unread</span> : null}</span></Button>;
          })}
          {chat.conversations.hasNextPage ? <Button variant="outline" disabled={chat.conversations.isFetchingNextPage} onClick={() => { void chat.conversations.fetchNextPage(); }}>More Conversations</Button> : null}
        </aside>
        <section className="flex min-h-0 min-w-0 flex-col gap-3 md:col-start-1 md:row-start-1" aria-label="Messages">
          {!convoId ? <p className="py-8 text-center text-sm text-muted-foreground">Select a Conversation.</p> : <>
            <div className="flex flex-wrap gap-2"><Button variant="outline" size="sm" disabled={chat.action.isPending} onClick={() => { void perform({ kind: active?.muted ? "unmute" : "mute", convoId }); }}>{active?.muted ? "Unmute" : "Mute"}</Button><Button variant="outline" size="sm" disabled={chat.action.isPending} onClick={() => { void perform({ kind: "read", convoId }); }}>Mark As Read</Button></div>
            <div ref={viewport} role="log" aria-label="Conversation History" className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto overscroll-contain pb-2" onTouchStart={event => {
              const point = event.touches[0];
              touch.current = event.touches.length === 1 && point && event.currentTarget.scrollTop <= 32 ? { x: point.clientX, y: point.clientY } : undefined;
            }} onTouchMove={event => {
              const start = touch.current;
              const point = event.touches[0];
              if (!start || !point || event.touches.length !== 1) { touch.current = undefined; return; }
              const dx = point.clientX - start.x;
              const dy = point.clientY - start.y;
              if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 20) { touch.current = undefined; return; }
              if (dy >= 40 && Math.abs(dy) > Math.abs(dx) && event.currentTarget.scrollTop <= 32) { touch.current = undefined; void loadOlder(); }
            }} onTouchEnd={() => { touch.current = undefined; }} onTouchCancel={() => { touch.current = undefined; }} onWheel={event => { if (event.deltaY < 0 && event.currentTarget.scrollTop <= 32) void loadOlder(); }} onScroll={event => {
              const top = event.currentTarget.scrollTop;
              const upward = top < scrollState.current.top;
              scrollState.current.top = top;
              scrollState.current.atBottom = event.currentTarget.scrollHeight - top - event.currentTarget.clientHeight <= 32;
              if (upward && top <= 32) void loadOlder();
            }}>
            {chat.messages.isFetchingNextPage ? <p role="status" className="text-center text-xs text-muted-foreground">Loading Older Messages…</p> : null}
            {chat.messages.isPending ? <p role="status">Loading Messages…</p> : messages.length ? messages.map((message, index) => <Fragment key={String(message.id)}>{messageDays[index] ? <div role="separator" aria-label={messageDays[index]} className="py-2 text-center text-xs font-medium text-muted-foreground">{messageDays[index]}</div> : null}<SocialChatMessage message={message} viewerDid={viewerDid} pending={chat.action.isPending} moderation={moderation} onDelete={setDeleteId} onReply={value => { setReply(value); document.getElementById("chat-message")?.focus(); }} onReaction={(messageId, value, remove) => { void perform({ kind: remove ? "removeReaction" : "addReaction", convoId, messageId, value }); }} /></Fragment>) : !chat.messages.isError ? <p className="text-sm text-muted-foreground">No Messages Yet.</p> : null}
            </div>
            {deleteId ? <div role="alert" className="space-y-2 rounded-lg border p-3"><p className="text-sm">Delete This Message For You? Other Participants Keep Their Copy.</p><div className="flex gap-2"><Button variant="destructive" disabled={chat.action.isPending} onClick={() => { void perform({ kind: "delete", convoId, messageId: deleteId }); }}>Delete For Me</Button><Button variant="outline" onClick={() => setDeleteId(undefined)}>Cancel</Button></div></div> : null}
            <form className="flex shrink-0 flex-col gap-2" onSubmit={event => { event.preventDefault(); void perform({ kind: "send", convoId, text: outgoing, replyTo: reply?.id }); }}>{reply !== undefined ? <div className="flex items-start gap-2 rounded-md border p-2 text-xs"><div className="min-w-0 flex-1"><span className="font-medium">Replying To</span><p className="line-clamp-2 whitespace-pre-wrap break-words text-muted-foreground">{reply.text}</p></div><Button type="button" variant="ghost" size="sm" disabled={chat.action.isPending} onClick={() => setReply(undefined)}>Cancel Reply</Button></div> : null}<SocialMessageInput id="chat-message" label="Message" text={text} onChange={setText} pending={chat.action.isPending} valid={!!text.trim() && ChatBskyConvoDefs.validateMessageInput({ text: outgoing.trim() }).success} onSend={() => { void perform({ kind: "send", convoId, text: outgoing, replyTo: reply?.id }); }} /></form>
          </>}
        </section>
      </div>
    </div>}
  </div>;
}
