"use client";
import { moderateProfile } from "@atproto/api";
import { Button } from "@/components/ui/button";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import type { StreamChatMessage } from "@/lib/livestream/livestreamTypes";
export function LivestreamChat({ messages, text, onChange, onSend, pending, connected }: { messages: StreamChatMessage[]; text: string; onChange: (text: string) => void; onSend: () => void; pending: boolean; connected: boolean }) {
  const catalog = useBlueskySocialCatalog();
  const moderation = catalog.data?.moderation;
  const visible = moderation && !catalog.isError ? messages.filter(item => { const decision = moderateProfile(item.author, moderation).ui("contentList"); return !decision.filter && !decision.blur && !decision.noOverride; }) : [];
  return <aside aria-label="Stream Chat" className="min-w-0 space-y-3 rounded-2xl border p-4 lg:flex lg:min-h-0 lg:flex-col lg:overflow-y-auto lg:overscroll-contain"><h2 className="shrink-0 font-semibold">Stream Chat</h2><p className="shrink-0 text-xs text-muted-foreground">Public Streamplace Chat. Only Recent Messages Retained By This Node Are Shown.</p>
    {!moderation || catalog.isError ? <p role="status" className="shrink-0">Chat Withheld Until Your Moderation Settings Are Available.</p> : null}
    <div role="log" aria-label="Stream Chat Messages" aria-live="polite" className="max-h-96 space-y-3 overflow-y-auto overscroll-contain lg:min-h-24 lg:flex-1 lg:max-h-none">{visible.map(item => <p key={item.uri} className="break-words text-sm"><strong>{item.author.displayName || item.author.handle}</strong><br />{item.record.text}</p>)}</div>
    <label className="block shrink-0 text-sm">Message<textarea aria-label="Stream Chat Message" value={text} onChange={event => onChange(event.target.value)} className="min-h-20 w-full rounded-md border bg-transparent p-2" /></label><Button className="shrink-0" disabled={pending || !text.trim() || !connected || !moderation || catalog.isError} onClick={onSend}>Send Message</Button></aside>;
}
