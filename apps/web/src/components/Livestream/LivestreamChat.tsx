"use client";
import { moderateProfile } from "@atproto/api";
import { Button } from "@/components/ui/button";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import type { StreamChatMessage } from "@/lib/livestream/livestreamTypes";
export function LivestreamChat({ messages, text, onChange, onSend, pending, connected }: { messages: StreamChatMessage[]; text: string; onChange: (text: string) => void; onSend: () => void; pending: boolean; connected: boolean }) {
  const catalog = useBlueskySocialCatalog();
  const moderation = catalog.data?.moderation;
  const visible = moderation && !catalog.isError ? messages.filter(item => { const decision = moderateProfile(item.author, moderation).ui("contentList"); return !decision.filter && !decision.blur && !decision.noOverride; }) : [];
  return <aside className="min-w-0 space-y-3 rounded-2xl border p-4"><h2 className="font-semibold">Stream Chat</h2><p className="text-xs text-muted-foreground">Public Streamplace Chat. Only Recent Messages Retained By This Node Are Shown.</p>
    {!moderation || catalog.isError ? <p role="status">Chat Withheld Until Your Moderation Settings Are Available.</p> : null}
    <div aria-live="polite" className="max-h-96 space-y-3 overflow-y-auto">{visible.map(item => <p key={item.uri} className="break-words text-sm"><strong>{item.author.displayName || item.author.handle}</strong><br />{item.record.text}</p>)}</div>
    <label className="block text-sm">Message<textarea aria-label="Stream Chat Message" value={text} onChange={event => onChange(event.target.value)} className="min-h-20 w-full rounded-md border bg-transparent p-2" /></label><Button disabled={pending || !text.trim() || !connected || !moderation || catalog.isError} onClick={onSend}>Send Message</Button></aside>;
}
