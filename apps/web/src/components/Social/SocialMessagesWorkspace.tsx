"use client";

import { BellOff, MoreHorizontal } from "lucide-react";
import { Fragment, useEffect, useLayoutEffect, useRef, useState } from "react";
import { ChatBskyConvoDefs, moderateProfile, type ChatBskyActorDefs } from "@atproto/api";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle } from "@/components/ui/dialog";
import { SocialConversationRow } from "./SocialConversationRow";
import { SocialChatReportDialog } from "./SocialChatReportDialog";
import { chatProfileSafety } from "@/lib/chatProfileSafety";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { Avatar } from "@/components/shared/Avatar";
import { floatingSidebarClassName } from "@/components/shared/floatingSidebarStyles";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { attachFloatingGlassScrollOverlay } from "@/components/shared/floatingGlassScrollOverlay";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { socialHttpsUrl } from "./socialUrls";
import { SocialMessageInput } from "./SocialMessageInput";
import { SocialNewConversationDialog } from "./SocialNewConversationDialog";
import { useBlueskyMessages } from "@/hooks/useBlueskyMessages";
import { LOCAL_CHAT_UNAVAILABLE, chatErrorMessage, type ChatAction } from "@/lib/blueskyChatClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialChatMessage } from "./SocialChatMessage";
import { chatMessageDays } from "@/lib/chatMessageDays";
import { chatConversationName } from "@/lib/chatConversationName";

export function SocialMessagesWorkspace({ viewerDid, draft = "" }: { viewerDid: string; draft?: string }) {
  const [convoId, setConvoId] = useState<string>();
  const { getOAuthSession } = useAuth();
  const lock = useRef(false);
  const createdBlocks = useRef(new Map<string, string>());
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const [reply, setReply] = useState<{ id: string; text: string }>();
  const [text, setText] = useState(draft);
  const [actionError, setActionError] = useState<string>();
  const [inbox, setInbox] = useState<"accepted" | "request">("accepted");
  const [confirm, setConfirm] = useState<{ kind: "leave" | "block" | "unblock"; convoId: string; subjectDid?: string }>();
  const [report, setReport] = useState<{ convoId: string; senderDid: string; messageId?: string }>();
  const [notice, setNotice] = useState<string>();
  const [blocked, setBlocked] = useState<Record<string, boolean>>({});
  const [deleteId, setDeleteId] = useState<string>();
  const chat = useBlueskyMessages(convoId);
  const catalog = useBlueskySocialCatalog({ enabled: chat.available });
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === viewerDid ? catalog.data?.moderation : undefined;
  const outgoing = text;
  function assertViewer() { if (!mounted.current || getOAuthSession()?.did !== viewerDid) throw new Error("Your account changed. Please reload Messages."); }
  const accepted = [...new Map((chat.conversations.data?.pages.flatMap(page => page.convos) ?? []).filter(convo => convo.status !== "request").map(convo => [convo.id, convo])).values()];
  const requests = [...new Map((chat.requests.data?.pages.flatMap(page => page.convos) ?? []).filter(convo => convo.status === "request").map(convo => [convo.id, convo])).values()];
  const convos = [...accepted, ...requests];
  // Retire a local mutation hint once the server confirms it, allowing later
  // changes from another client to remain authoritative. The guarded adjustment
  // settles before children render and does not add an effect/render waterfall.
  const syncedMembers = convos.flatMap(convo => convo.members);
  const pendingBlocks = Object.entries(blocked).filter(([did, value]) => !syncedMembers.some(member => member.did === did && !!member.viewer?.blocking === value));
  if (pendingBlocks.length !== Object.keys(blocked).length) setBlocked(Object.fromEntries(pendingBlocks));
  const visibleConvos = inbox === "request" ? requests : accepted;
  const listing = inbox === "request" ? chat.requests : chat.conversations;
  const active = convos.find(convo => convo.id === convoId);
  const pendingRequest = active?.status === "request";
  function safetyFor(did: string) {
    const member = active?.members.find(member => member.did === did);
    if (blocked[did]) return { hidden: true, noOverride: true };
    return chatProfileSafety(member ? withBlockState(member) : undefined, viewerDid, moderation);
  }
  function previewHidden(convo: ChatBskyConvoDefs.ConvoView) {
    if (!convo.lastMessage) return false;
    const senderDid = convo.lastMessage && "sender" in convo.lastMessage ? convo.lastMessage.sender.did : undefined;
    if (senderDid && blocked[senderDid]) return true;
    return chatProfileSafety(convo.members.map(withBlockState).find(member => member.did === senderDid), viewerDid, moderation).hidden;
  }
  function withBlockState(member: ChatBskyActorDefs.ProfileViewBasic) {
    if (blocked[member.did] === undefined) return member;
    return { ...member, viewer: { ...member.viewer, blocking: blocked[member.did] ? `at://${viewerDid}/app.bsky.graph.block/local` : undefined } };
  }
  function contact(member: ChatBskyActorDefs.ProfileViewBasic) {
    member = withBlockState(member);
    const safety = moderation ? moderateProfile({ ...member, $type: "app.bsky.actor.defs#profileViewBasic" }, moderation) : undefined;
    const hidden = (context: "profileList" | "displayName" | "avatar") => { const ui = safety?.ui(context); return !ui || ui.filter || ui.blur || ui.noOverride; };
    return { name: hidden("profileList") || hidden("displayName") ? "Account" : member.displayName || member.handle, avatar: hidden("profileList") || hidden("avatar") ? undefined : socialHttpsUrl(member.avatar) };
  }
  const activeMembers = active?.members.filter(member => member.did !== viewerDid) ?? [];
  const group = ChatBskyConvoDefs.isGroupConvo(active?.kind) ? active.kind : undefined;
  const isGroup = !!group || activeMembers.length > 1;
  const unavailableRecipient = !isGroup && activeMembers.some(member => (blocked[member.did] ?? !!member.viewer?.blocking) || member.viewer?.blockedBy || member.chatDisabled);
  const viewerDisabled = !!active?.members.find(member => member.did === viewerDid)?.chatDisabled;
  const locked = !!group && group.lockStatus !== "unlocked";
  const canParticipate = !!moderation && !!active && !pendingRequest && !unavailableRecipient && !viewerDisabled && !locked;
  function replyHidden(message: unknown) {
    if (!message || typeof message !== "object" || !("replyTo" in message)) return false;
    if (!ChatBskyConvoDefs.isMessageView(message.replyTo)) return false;
    const result = ChatBskyConvoDefs.validateMessageView(message.replyTo);
    return !result.success || safetyFor(result.value.sender.did).hidden;
  }
  const headerContact = activeMembers[0] ?? active?.members.find(member => member.did === viewerDid);
  const firstContact = headerContact ? contact(headerContact) : undefined;
  const header = active ? { avatar: firstContact?.avatar, name: chatConversationName(active, activeMembers.length ? activeMembers.map(contact).map(member => member.name) : firstContact ? [firstContact.name] : []) } : undefined;
  const confirmedConversation = confirm?.kind === "leave" ? convos.find(convo => convo.id === confirm.convoId) : undefined;
  const confirmedConversationName = confirmedConversation ? chatConversationName(confirmedConversation, confirmedConversation.members.filter(member => member.did !== viewerDid).map(contact).map(member => member.name)) : undefined;
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
  const error = actionError ?? (listing.isError ? chatErrorMessage(listing.error) : chat.messages.isError ? chatErrorMessage(chat.messages.error) : catalog.isError ? chatErrorMessage(catalog.error) : undefined);
  async function perform(action: ChatAction) {
    if (lock.current) return;
    lock.current = true; setActionError(undefined);
    try {
      assertViewer();
      if ((action.kind === "send" || action.kind === "addReaction" || action.kind === "removeReaction") && (!canParticipate || action.convoId !== active?.id)) throw new Error("This conversation is not available for replies.");
      const result = await chat.perform(action);
      assertViewer();
      if (action.kind === "start" && "convo" in result) setConvoId(result.convo.id);
      if (action.kind === "send") { setText(""); setReply(undefined); }
      if (action.kind === "delete") setDeleteId(undefined);
      if (action.kind === "accept") setInbox("accepted");
      if (action.kind === "leave") {
        if (convoId === action.convoId) { setConvoId(undefined); setReply(undefined); setText(""); setDeleteId(undefined); }
        setConfirm(undefined);
      }
      if (action.kind === "block" || action.kind === "unblock") {
        if (action.kind === "block" && "uri" in result && typeof result.uri === "string") createdBlocks.current.set(action.subjectDid, result.uri);
        if (action.kind === "unblock") createdBlocks.current.delete(action.subjectDid);
        setBlocked(previous => ({ ...previous, [action.subjectDid]: action.kind === "block" }));
        setConfirm(undefined);
      }
      if (action.kind === "report") { setReport(undefined); setNotice("Report Sent to Bluesky Moderation."); }
    } catch (failure) { if (mounted.current) setActionError(chatErrorMessage(failure)); }
    finally { lock.current = false; }
  }
  return <div className="flex min-h-0 flex-1 flex-col">
    <FeedHeader title={header?.name ?? "Messages"} subtitle={pendingRequest ? "Pending Message Request" : active?.muted ? "Muted Conversation" : isGroup ? `${group?.memberCount ?? activeMembers.length + 1} Participants` : active ? "Private Conversation" : "Private Conversations"} leading={header ? <Avatar src={header.avatar} alt="" size={36} className="shrink-0" /> : undefined} >
      {active ? <div className="flex shrink-0 items-center gap-1"><Button variant="outline" size="sm" disabled={chat.action.isPending} onClick={() => { void perform({ kind: active.muted ? "unmute" : "mute", convoId: active.id }); }}>{active.muted ? <BellOff aria-hidden className="size-4" /> : null}{active.muted ? "Unmute" : "Mute"}</Button>
        <DropdownMenu><DropdownMenuTrigger disabled={chat.action.isPending} aria-label="Conversation Actions" render={<Button variant="ghost" size="icon-sm" />}><MoreHorizontal className="size-4" /></DropdownMenuTrigger><DropdownMenuContent align="end" className="w-max min-w-56 whitespace-nowrap">
          <DropdownMenuItem disabled={active.unreadCount === 0} onClick={() => { void perform({ kind: "read", convoId: active.id }); }}>Mark As Read</DropdownMenuItem>
          {activeMembers.filter(member => member.did !== viewerDid).map(member => {
            const isBlocked = blocked[member.did] ?? !!member.viewer?.blocking;
            return <DropdownMenuItem key={member.did} onClick={() => { setActionError(undefined); setConfirm({ kind: isBlocked ? "unblock" : "block", convoId: active.id, subjectDid: member.did }); }}>{isBlocked ? "Unblock" : "Block"} {activeMembers.length > 1 ? contact(member).name : "Account"}</DropdownMenuItem>;
          })}
          {activeMembers[0] ? <DropdownMenuItem onClick={() => { setActionError(undefined); setReport({ convoId: active.id, senderDid: activeMembers[0].did }); }}>Report Conversation</DropdownMenuItem> : null}
          <DropdownMenuSeparator /><DropdownMenuItem variant="destructive" onClick={() => { setActionError(undefined); setConfirm({ kind: "leave", convoId: active.id }); }}>Delete Conversation</DropdownMenuItem>
        </DropdownMenuContent></DropdownMenu>
      </div> : null}
    </FeedHeader>
    {!chat.available ? <section role="status" className="space-y-2 p-6"><h2 className="font-semibold">Messages Unavailable Locally</h2><p className="text-sm text-muted-foreground">{LOCAL_CHAT_UNAVAILABLE}</p></section> : <div className="flex min-h-0 flex-1 flex-col overflow-hidden p-3 sm:p-4">
      {error ? <section role="alert" className="mb-4 rounded-lg border p-3"><p className="text-sm">{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" onClick={() => { void listing.refetch(); void catalog.refetch(); if (convoId) void chat.messages.refetch(); }}>Retry</Button>}</section> : null}
      {notice ? <p role="status" className="mb-3 text-sm">{notice}</p> : null}
      <div className="grid min-h-0 w-full flex-1 grid-rows-[auto_minmax(0,1fr)] gap-4 md:grid-cols-[minmax(0,1fr)_300px] xl:grid-cols-[minmax(0,1fr)_340px] md:grid-rows-[minmax(0,1fr)]">
        <aside className={`${floatingSidebarClassName} max-h-64 w-full min-h-0 space-y-3 overflow-y-auto overscroll-contain md:col-start-2 md:row-start-1 md:max-h-full`} aria-label="Conversations">
          <h2 className="px-2 text-sm font-semibold">Conversations</h2>
          <SocialNewConversationDialog initialMessage={text} disabled={chat.action.isPending} perform={chat.perform} assertViewer={assertViewer} onSent={id => { setConvoId(id); setText(""); setReply(undefined); setActionError(undefined); }} />
          <div className="flex gap-1" aria-label="Conversation Inbox"><Button variant={inbox === "accepted" ? "secondary" : "ghost"} size="sm" aria-pressed={inbox === "accepted"} onClick={() => setInbox("accepted")}>Chats</Button><Button variant={inbox === "request" ? "secondary" : "ghost"} size="sm" aria-pressed={inbox === "request"} onClick={() => setInbox("request")}>Pending{requests.length ? ` (${requests.length}${chat.requests.hasNextPage ? "+" : ""})` : ""}</Button></div>
          {listing.isPending ? <p role="status" className="text-sm text-muted-foreground">Loading Conversations…</p> : !visibleConvos.length && !listing.isError ? <p className="text-sm text-muted-foreground">{inbox === "request" ? "No Pending Requests." : "No Conversations Yet."}</p> : null}
          {visibleConvos.map(convo => {
            const contacts = convo.members.filter(member => member.did !== viewerDid);
            const safeContacts = contacts.map(contact);
            const name = chatConversationName(convo, safeContacts.map(contact => contact.name));
            return <SocialConversationRow key={convo.id} convo={convo} viewerDid={viewerDid} name={name} avatar={safeContacts[0]?.avatar} selected={convo.id === convoId} pending={chat.action.isPending} previewHidden={previewHidden(convo)} onSelect={() => { setConvoId(convo.id); setActionError(undefined); setNotice(undefined); setDeleteId(undefined); setReply(undefined); }} onAction={kind => { setActionError(undefined); if (kind === "leave") setConfirm({ kind, convoId: convo.id }); else void perform({ kind, convoId: convo.id }); }} />;
          })}
          {listing.hasNextPage ? <Button variant="outline" disabled={listing.isFetchingNextPage} onClick={() => { void listing.fetchNextPage(); }}>More Conversations</Button> : null}
        </aside>
        <section className="mx-auto flex min-h-0 w-full min-w-0 max-w-2xl flex-col justify-self-center md:col-start-1 md:row-start-1" aria-label="Messages">
          {!convoId ? <p className="py-8 text-center text-sm text-muted-foreground">Select a Conversation.</p> : <>
            {pendingRequest ? <section aria-label="Message Request" className="mb-3 space-y-2 rounded-lg border p-3"><p className="text-sm">Accept this request to reply. Link and attachment previews stay hidden until you accept.</p><div className="flex flex-wrap gap-2"><Button disabled={chat.action.isPending} onClick={() => { void perform({ kind: "accept", convoId }); }}>Accept Request</Button><Button variant="outline" disabled={chat.action.isPending} onClick={() => setConfirm({ kind: "leave", convoId })}>Delete Request</Button></div></section> : null}
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
            {chat.messages.isPending ? <p role="status">Loading Messages…</p> : messages.length ? messages.map((message, index) => <Fragment key={String(message.id)}>{messageDays[index] ? <div role="separator" aria-label={messageDays[index]} className="py-2 text-center text-xs font-medium text-muted-foreground">{messageDays[index]}</div> : null}<SocialChatMessage message={message} viewerDid={viewerDid} pending={chat.action.isPending} moderation={moderation} contentHidden={ChatBskyConvoDefs.isMessageView(message) ? safetyFor(message.sender.did).hidden : false} noOverride={ChatBskyConvoDefs.isMessageView(message) ? safetyFor(message.sender.did).noOverride : true} suppressPreviews={pendingRequest} replyHidden={replyHidden(message)} canInteract={canParticipate} onReport={(messageId, senderDid) => { setActionError(undefined); setReport({ convoId, messageId, senderDid }); }} onDelete={setDeleteId} onReply={value => { setReply(value); document.getElementById("chat-message")?.focus(); }} onReaction={(messageId, value, remove) => { void perform({ kind: remove ? "removeReaction" : "addReaction", convoId, messageId, value }); }} /></Fragment>) : !chat.messages.isError ? <p className="text-sm text-muted-foreground">No Messages Yet.</p> : null}
            </div>
            <div ref={surface => surface ? attachFloatingGlassScrollOverlay(surface, "bottom") : undefined} className="relative z-20 mt-3 mb-[var(--mobile-navigation-clearance,0px)] flex shrink-0 flex-col gap-3">
            {deleteId ? <div role="alert" className="space-y-2 rounded-lg border p-3"><p className="text-sm">Delete This Message For You? Other Participants Keep Their Copy.</p><div className="flex gap-2"><Button variant="destructive" disabled={chat.action.isPending} onClick={() => { void perform({ kind: "delete", convoId, messageId: deleteId }); }}>Delete For Me</Button><Button variant="outline" onClick={() => setDeleteId(undefined)}>Cancel</Button></div></div> : null}
            {canParticipate ? <form className="flex shrink-0 flex-col gap-2" onSubmit={event => { event.preventDefault(); void perform({ kind: "send", convoId, text: outgoing, replyTo: reply?.id }); }}>{reply !== undefined ? <div className={`${floatingGlassClasses} flex items-start gap-2 p-2 text-xs`}><div className="min-w-0 flex-1"><span className="font-medium">Replying To</span><p className="line-clamp-2 whitespace-pre-wrap break-words text-muted-foreground">{reply.text}</p></div><Button type="button" variant="ghost" size="sm" disabled={chat.action.isPending} onClick={() => setReply(undefined)}>Cancel Reply</Button></div> : null}<SocialMessageInput id="chat-message" label="Message" text={text} onChange={setText} pending={chat.action.isPending} valid={!!text.trim() && ChatBskyConvoDefs.validateMessageInput({ text: outgoing.trim() }).success} onSend={() => { void perform({ kind: "send", convoId, text: outgoing, replyTo: reply?.id }); }} /></form> : !pendingRequest && active ? <p role="status" className="text-sm text-muted-foreground">{!moderation && !catalog.isError ? "Loading Moderation Settings…" : locked ? "This Conversation Is Locked." : "This Conversation Is Not Available for Replies."}</p> : null}
            </div>
          </>}
        </section>
      </div>
    </div>}
    {confirm ? <Dialog open onOpenChange={open => { if (!open && !chat.action.isPending) setConfirm(undefined); }}><DialogContent showCloseButton={!chat.action.isPending}>
      <DialogTitle>{confirm.kind === "leave" ? "Delete Conversation?" : confirm.kind === "block" ? "Block Account?" : "Unblock Account?"}</DialogTitle>
      <DialogDescription>{confirm.kind === "leave" ? `This deletes ${confirmedConversationName ? `“${confirmedConversationName}”` : "the conversation"} for you. Other participants keep their messages.` : confirm.kind === "block" ? "This account will be blocked across Bluesky. You can unblock it later." : "This removes your Bluesky block for this account."}</DialogDescription>
      {actionError ? <p role="alert" className="text-destructive">{actionError}</p> : null}
      <DialogFooter><DialogClose disabled={chat.action.isPending} render={<Button variant="outline" />}>Cancel</DialogClose><Button variant={confirm.kind === "unblock" ? "default" : "destructive"} disabled={chat.action.isPending} onClick={() => { if (confirm.kind === "leave") void perform({ kind: "leave", convoId: confirm.convoId }); else if (confirm.subjectDid) void perform({ kind: confirm.kind, convoId: confirm.convoId, subjectDid: confirm.subjectDid, ...(confirm.kind === "unblock" && createdBlocks.current.has(confirm.subjectDid) ? { blockingUri: active?.members.find(member => member.did === confirm.subjectDid)?.viewer?.blocking ?? createdBlocks.current.get(confirm.subjectDid) } : {}) }); }}>{confirm.kind === "leave" ? "Delete Conversation" : confirm.kind === "block" ? "Block Account" : "Unblock Account"}</Button></DialogFooter>
    </DialogContent></Dialog> : null}
    {report ? <SocialChatReportDialog key={`${report.convoId}:${report.messageId ?? "conversation"}`} pending={chat.action.isPending} error={actionError} onClose={() => setReport(undefined)} onSubmit={(reasonType, reason) => { void perform({ kind: "report", ...report, reasonType, reason }); }} /> : null}
  </div>;
}
