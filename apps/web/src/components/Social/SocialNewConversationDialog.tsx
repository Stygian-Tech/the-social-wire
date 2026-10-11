"use client";

import { useEffect, useRef, useState } from "react";
import { ChatBskyConvoDefs } from "@atproto/api";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import type { ChatAction } from "@/lib/blueskyChatClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialMessageInput } from "./SocialMessageInput";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialNewConversationDialog({ initialMessage, disabled, perform, assertViewer, onSent }: { initialMessage: string; disabled: boolean; perform: (action: ChatAction) => Promise<unknown>; assertViewer: () => void; onSent: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  const [recipient, setRecipient] = useState("");
  const [text, setText] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [createdId, setCreatedId] = useState<string>();
  const created = useRef<string | undefined>(undefined);
  const lock = useRef(false);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  function changeOpen(value: boolean) {
    if (lock.current) return;
    if (value) { setRecipient(""); setText(initialMessage); setError(undefined); created.current = undefined; setCreatedId(undefined); }
    setOpen(value);
  }
  async function send() {
    if (lock.current || disabled || !recipient.trim() || !ChatBskyConvoDefs.validateMessageInput({ text: text.trim() }).success || !text.trim()) return;
    lock.current = true; setPending(true); setError(undefined);
    try {
      assertViewer();
      if (!created.current) {
        const result = await perform({ kind: "start", members: [recipient.trim()] });
        assertViewer();
        if (!mounted.current) return;
        if (!result || typeof result !== "object" || !("convo" in result) || !result.convo || typeof result.convo !== "object" || !("id" in result.convo) || typeof result.convo.id !== "string" || !result.convo.id) throw new Error("The conversation could not be opened.");
        created.current = result.convo.id; setCreatedId(result.convo.id);
      }
      await perform({ kind: "send", convoId: created.current, text });
      assertViewer();
      if (mounted.current) { onSent(created.current); setOpen(false); }
    } catch (failure) { if (mounted.current) setError(socialErrorMessage(failure) === SCOPE_RECOVERY_MESSAGE ? SCOPE_RECOVERY_MESSAGE : failure instanceof Error && /account changed/i.test(failure.message) ? failure.message : "This conversation action could not be completed. Please try again."); }
    finally { lock.current = false; if (mounted.current) setPending(false); }
  }
  return <Dialog open={open} onOpenChange={changeOpen}>
    <DialogTrigger render={<Button disabled={disabled} className="w-full" />}>New Conversation</DialogTrigger>
    <DialogContent>
      <DialogTitle>New Conversation</DialogTitle><DialogDescription>Choose a recipient and send your first message.</DialogDescription>
      <form className="flex flex-col gap-3" onSubmit={event => { event.preventDefault(); void send(); }}>
        <label className="flex flex-col gap-1 text-sm">Recipient Handle Or DID<input disabled={pending || !!createdId} value={recipient} onChange={event => setRecipient(event.target.value)} className="rounded-md border bg-background px-3 py-2" placeholder="alice.bsky.social" /></label>
        <SocialMessageInput id="chat-first-message" label="First Message" text={text} onChange={setText} pending={pending} valid={!!recipient.trim() && !!text.trim() && ChatBskyConvoDefs.validateMessageInput({ text: text.trim() }).success} onSend={() => { void send(); }} />
        {error ? <div role="alert" className="text-sm text-destructive">{error}{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}{createdId ? <p className="mt-1 text-muted-foreground">The conversation is open. Check it before retrying; the message may already have been delivered.</p> : null}</div> : null}
        <div className="flex justify-end gap-2"><DialogClose render={<Button variant="outline" disabled={pending} />}>Cancel</DialogClose></div>
      </form>
    </DialogContent>
  </Dialog>;
}
