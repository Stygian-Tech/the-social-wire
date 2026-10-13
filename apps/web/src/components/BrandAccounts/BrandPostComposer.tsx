"use client";

import { useComposeLinkPreview } from "@/hooks/useComposeLinkPreview";
import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { SocialComposeLinkCard } from "@/components/Social/SocialComposeLinkCard";
import { useRef, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { moderateProfile, type AppBskyActorDefs, type AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { postTextLength } from "@/lib/blueskyComposeClient";
import { getSocialExplorePage } from "@/lib/blueskySocialDiscoveryClient";
import { insertSocialMention, socialMentionAtCaret } from "@/lib/socialMentionTypeahead";
import { Avatar } from "@/components/shared/Avatar";
import { socialHttpsUrl } from "@/components/Social/socialUrls";
import { SocialComposePreview } from "@/components/Social/SocialComposePreview";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";

export function BrandPostComposer({ ownerDid, session, moderation, profile, parent, pending, publish, close, assertCurrentActor, inline = false, scheduling }: { scheduling?: { controls: ReactNode; submitLabel: string; pendingLabel: string; valid: boolean }; inline?: boolean; ownerDid: string; session: OAuthSession; moderation: ModerationOpts; profile: AppBskyActorDefs.ProfileViewDetailed | undefined; parent?: AppBskyFeedDefs.PostView; pending: boolean; publish: (text: string, linkPreview?: ComposeLinkPreview) => Promise<void>; close: () => void; assertCurrentActor: () => void }) {
  const [text, setText] = useState("");
  const link = useComposeLinkPreview(text, session);
  const [caret, setCaret] = useState(0);
  const [error, setError] = useState<string>();
  const ref = useRef<HTMLTextAreaElement>(null);
  const mention = socialMentionAtCaret(text, caret);
  const people = useQuery({ queryKey: ["brandAccounts", ownerDid, session.did, "mentions", mention?.query], enabled: !!mention, queryFn: async ({ signal }) => { assertCurrentActor(); const result = await getSocialExplorePage({ session, moderation, query: mention!.query, kind: "people", signal }); assertCurrentActor(); return result; }, retry: false });
  const length = postTextLength(text);
  const profileDecision = profile ? moderateProfile(profile, moderation) : undefined;
  const avatarAllowed = profileDecision && !["filter", "blur", "noOverride"].some(flag => profileDecision.ui("avatar")[flag as "filter" | "blur" | "noOverride"]);
  const nameAllowed = profileDecision && !["filter", "blur", "noOverride"].some(flag => profileDecision.ui("displayName")[flag as "filter" | "blur" | "noOverride"]);
  async function submit() {
    if (pending || link.loading) return;
    setError(undefined);
    try { await publish(text, link.preview); close(); } catch (failure) { setError(failure instanceof Error ? failure.message : "This Post Could Not Be Published."); }
  }
  const content = <>
    <div className="flex items-center gap-2"><Avatar src={avatarAllowed ? socialHttpsUrl(profile?.avatar) : undefined} alt="" size={32} /><p className="min-w-0 break-all text-xs">{nameAllowed && profile?.displayName || profile?.handle || session.did}<span className="block text-muted-foreground">{session.did}</span></p></div>
    {parent ? <blockquote className="max-h-32 overflow-y-auto border-l-2 pl-3 text-sm"><span className="block text-xs text-muted-foreground">Replying to @{parent.author.handle}</span>{typeof (parent.record as { text?: unknown }).text === "string" ? String((parent.record as { text: string }).text) : "Post"}</blockquote> : null}
    <form className="space-y-3" onSubmit={event => { event.preventDefault(); void submit(); }}><label className="sr-only" htmlFor="brand-post-text">Brand Post Text</label><textarea id="brand-post-text" ref={ref} autoFocus rows={6} className="w-full rounded-xl border bg-background p-3" disabled={pending} value={text} onChange={event => { setText(event.target.value); setCaret(event.target.selectionStart); }} onSelect={event => setCaret(event.currentTarget.selectionStart)} placeholder="Write a Post…" />
      {mention ? <div role="listbox" aria-label="Brand Mention Suggestions" className="max-h-40 overflow-y-auto rounded-xl border p-1">{people.data?.actors.filter(actor => { const decision = moderateProfile(actor, moderation).ui("profileList"); return !decision.filter && !decision.blur && !decision.noOverride; }).slice(0, 6).map(actor => <button type="button" role="option" aria-selected="false" key={actor.did} className="block w-full rounded-lg px-2 py-1 text-left text-sm hover:bg-accent" onClick={() => { const next = insertSocialMention(text, mention, actor.handle); setText(next.text); setCaret(next.caret); requestAnimationFrame(() => { ref.current?.focus(); ref.current?.setSelectionRange(next.caret, next.caret); }); }}>@{actor.handle}</button>)}{people.isPending ? <p role="status" className="p-2 text-xs">Loading People…</p> : people.isError ? <p className="p-2 text-xs">People Could Not Be Loaded</p> : !people.data?.actors.length ? <p className="p-2 text-xs">No Matching People</p> : null}</div> : null}
      <SocialComposePreview text={text} />
      <SocialComposeLinkCard {...link} disabled={pending} />
      <p className="text-right text-xs text-muted-foreground">{length.graphemes}/300</p>{scheduling?.controls}{error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}<div className="flex justify-end gap-2"><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || link.loading || !text.trim() || length.graphemes > 300 || length.bytes > 3000 || scheduling?.valid === false}>{pending ? scheduling?.pendingLabel || "Publishing…" : scheduling?.submitLabel || (parent ? "Post Reply" : "Post")}</Button></div>
    </form>
  </>;
  if (inline) return content;
  return <Dialog open onOpenChange={value => { if (!value && !pending) close(); }}><DialogContent showCloseButton={!pending} className="sm:max-w-xl"><DialogTitle>{parent ? "Reply as Brand Account" : "Compose as Brand Account"}</DialogTitle><DialogDescription>Publishing as {profile?.handle ? `@${profile.handle}` : session.did}</DialogDescription>{content}</DialogContent></Dialog>;
}
