"use client";

import { useId, useLayoutEffect, useRef } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { useComposeLinkPreview } from "@/hooks/useComposeLinkPreview";
import { postTextLength } from "@/lib/blueskyComposeClient";
import { composeLinkUrl, type ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { SocialPeopleTextField } from "./SocialPeopleTextField";
import { SocialComposePreview } from "./SocialComposePreview";
import { SocialComposeLinkCard } from "./SocialComposeLinkCard";
import type { ComposerMedia } from "@/lib/composerMedia";
import { SocialMediaControls } from "./SocialMediaControls";
import { Button } from "@/components/ui/button";

export function SocialThreadSegment({ text, index, total, disabled, session, open, onChange, onMove, onDelete, registerPreview, removedUrl, rememberRemovedUrl, media, updateMedia, mediaDisabled }: {
  media?: ComposerMedia; updateMedia?: (change: (previous?: ComposerMedia) => ComposerMedia | undefined) => void; mediaDisabled?: boolean;
  text: string; index: number; total: number; disabled: boolean; session: OAuthSession | null | undefined; open: boolean;
  onChange: (text: string) => void; onMove: (direction: -1 | 1) => void; onDelete: () => void;
  removedUrl?: string; rememberRemovedUrl: (url: string | undefined) => void;
  registerPreview: (resolve: (() => Promise<ComposeLinkPreview | undefined>) | undefined) => void;
}) {
  const id = useId();
  const intake = useRef<((files: File[]) => void) | undefined>(undefined);
  const link = useComposeLinkPreview(text, session, open && !media, removedUrl);
  useLayoutEffect(() => {
    registerPreview(async () => link.needsResolution ? await link.resolve() : link.preview);
    return () => registerPreview(undefined);
  });
  const { graphemes, bytes } = postTextLength(text);
  return <section className="flex min-w-0 flex-col gap-3" aria-label={`Post ${index + 1}`} onDragOver={event => { if (!disabled && !mediaDisabled && event.dataTransfer.types.includes("Files")) event.preventDefault(); }} onDrop={event => { if (!disabled && !mediaDisabled && event.dataTransfer.files.length) { event.preventDefault(); intake.current?.(Array.from(event.dataTransfer.files)); } }} onPaste={event => { const files = Array.from(event.clipboardData.files); if (!disabled && !mediaDisabled && files.length) { event.preventDefault(); intake.current?.(files); } }}>
    {total > 1 ? <div className="flex items-center justify-between gap-2"><span className="text-sm font-medium">Post {index + 1} of {total}</span><div className="flex gap-1">
      <Button type="button" variant="ghost" size="sm" disabled={disabled || index === 0} onClick={() => onMove(-1)} aria-label={`Move Post ${index + 1} Up`}>Move Up</Button>
      <Button type="button" variant="ghost" size="sm" disabled={disabled || index === total - 1} onClick={() => onMove(1)} aria-label={`Move Post ${index + 1} Down`}>Move Down</Button>
      <Button type="button" variant="ghost" size="sm" disabled={disabled} onClick={onDelete} aria-label={`Delete Post ${index + 1}`}>Delete</Button>
    </div></div> : null}
    <label htmlFor={id} className="sr-only">{index === 0 ? "Post Text" : `Post ${index + 1} Text`}</label>
    <SocialPeopleTextField id={id} autoFocus={index === 0} value={text} disabled={disabled} onValueChange={onChange} rows={total > 1 ? 4 : 6} placeholder={index === 0 ? "What's Happening?" : "Continue Your Thread…"} className="w-full resize-y rounded-xl border bg-background p-3 text-base leading-relaxed" />
    <SocialComposePreview text={text} />
    {updateMedia ? <SocialMediaControls media={media} update={updateMedia} session={session} disabled={disabled || !!mediaDisabled} hasLink={!!link.preview || link.loading} removeLink={() => { link.remove(); rememberRemovedUrl(composeLinkUrl(text)); }} registerIntake={intake} /> : null}
    <SocialComposeLinkCard {...link} remove={() => { link.remove(); rememberRemovedUrl(composeLinkUrl(text)); }} disabled={disabled} />
    <p aria-live="polite" className={`text-right text-sm ${graphemes > 300 ? "text-destructive" : "text-muted-foreground"}`}>{graphemes}/300</p>
    {bytes > 3000 ? <p className="text-sm text-destructive">Post Text Exceeds the Size Limit</p> : null}
  </section>;
}
