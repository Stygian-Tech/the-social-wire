"use client";

/* eslint-disable @next/next/no-img-element -- Local attachments use temporary object URLs. */
import { useEffect, useId, useRef, useState } from "react";
import { AppBskyFeedPost, RichText } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { useComposeLinkPreview } from "@/hooks/useComposeLinkPreview";
import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { livePostText } from "@/lib/livePosts/livePostContent";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";
import { validateLiveUpdateAttachments, type LiveUpdateAttachmentsDraft } from "@/lib/livePosts/livePostMedia";
import { handlePostComposerShortcut } from "@/lib/postComposerShortcut";
import { livePostErrorMessage } from "@/lib/livePosts/livePostErrorMessage";
import { SocialPeopleTextField } from "@/components/Social/SocialPeopleTextField";
import { SocialComposeLinkCard } from "@/components/Social/SocialComposeLinkCard";
import { Button } from "@/components/ui/button";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";

type Props = {
  event: LiveEvent;
  text: string;
  onTextChange: (value: string) => void;
  attachments: LiveUpdateAttachmentsDraft;
  onAttachmentsChange: (value: LiveUpdateAttachmentsDraft) => void;
  pending: boolean;
  failure?: string;
  onPublish: (linkPreview?: ComposeLinkPreview) => Promise<void> | void;
};

function AttachmentPreview({ file, alt, video = false }: { file: Blob; alt: string; video?: boolean }) {
  const imageElement = useRef<HTMLImageElement>(null);
  const videoElement = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const next = URL.createObjectURL(file);
    const element = video ? videoElement.current : imageElement.current;
    if (element) element.src = next;
    return () => { element?.removeAttribute("src"); URL.revokeObjectURL(next); };
  }, [file, video]);
  return video ? <video ref={videoElement} controls aria-label={alt || "Video Preview"} className="max-h-56 rounded-lg" /> : <img ref={imageElement} alt={alt} className="max-h-40 rounded-lg object-contain" />;
}

export function LivePostUpdateComposer({ event, text, onTextChange, attachments, onAttachmentsChange, pending, failure, onPublish }: Props) {
  const id = useId();
  const { getOAuthSession } = useAuth();
  const [resolving, setResolving] = useState(false);
  const [localError, setLocalError] = useState<string>();
  const publishing = useRef(false);
  const mounted = useRef(false);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const images = attachments.images ?? [];
  const hasMedia = !!(images.length || attachments.video || attachments.gif);
  const link = useComposeLinkPreview(text, getOAuthSession?.(), !hasMedia);
  const busy = pending || resolving;
  const blueskyText = livePostText(`${event.title}\n\n${text}`, event.tags);
  const validText = event.destination === "blog" || AppBskyFeedPost.validateRecord({ $type: "app.bsky.feed.post", text: blueskyText, createdAt: new Date().toISOString() }).success;
  const gifValid = !attachments.gif || (() => { try { return new URL(attachments.gif.url).protocol === "https:"; } catch { return false; } })();
  let attachmentError: string | undefined;
  try { validateLiveUpdateAttachments(attachments); } catch (error) { attachmentError = error instanceof Error ? error.message : "Check Your Attachments."; }
  const valid = (!!text.trim() || hasMedia) && validText && gifValid && !attachmentError && !event.endedAt;

  function change(value: LiveUpdateAttachmentsDraft) {
    setLocalError(undefined);
    onAttachmentsChange(value);
  }
  async function publish() {
    if (busy || publishing.current || !valid) return;
    publishing.current = true;
    setResolving(true);
    setLocalError(undefined);
    try {
      const preview = hasMedia ? undefined : link.needsResolution ? await link.resolve() : link.preview;
      if (!mounted.current) return;
      await onPublish(preview);
    } catch (error) { if (mounted.current) setLocalError(livePostErrorMessage(error)); }
    finally { publishing.current = false; if (mounted.current) setResolving(false); }
  }
  return <form aria-label="Live Update Composer" className={`${floatingGlassClasses} mb-6 flex flex-col gap-3 p-4`} onKeyDown={handlePostComposerShortcut} onSubmit={submit => { submit.preventDefault(); void publish(); }}>
    <label htmlFor={`${id}-text`} className="text-sm font-medium">Update</label>
    <SocialPeopleTextField id={`${id}-text`} value={text} onValueChange={onTextChange} disabled={busy} rows={5} placeholder="What Is Happening?" className="min-h-32 w-full resize-y rounded-lg border bg-background/30 p-3 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring" />
    <p className="text-xs text-muted-foreground">Add Links and @Mentions in Your Update.</p>
    <fieldset disabled={busy} className="flex flex-wrap gap-3 text-sm">
      <legend className="mb-2 font-medium">Attachments</legend>
      <label className="flex flex-col gap-1">Add Images<input aria-label="Add Images" type="file" accept="image/jpeg,image/png,image/webp" multiple disabled={busy || !!attachments.video || !!attachments.gif || images.length >= 4} className="max-w-full text-xs" onChange={input => {
        const files = Array.from(input.target.files ?? []);
        input.target.value = "";
        if (images.length + files.length > 4) { setLocalError("Choose Up to Four Images."); return; }
        if (files.some(file => !["image/jpeg", "image/png", "image/webp"].includes(file.type))) { setLocalError("Choose JPEG, PNG, or WebP Images."); return; }
        change({ images: [...images, ...files.map(file => ({ file, alt: "" }))] });
      }} /></label>
      <label className="flex flex-col gap-1">Add Video<input aria-label="Add Video" type="file" accept="video/mp4" disabled={busy || hasMedia} className="max-w-full text-xs" onChange={input => {
        const file = input.target.files?.[0];
        input.target.value = "";
        if (!file) return;
        if (file.type !== "video/mp4") { setLocalError("Choose an MP4 Video."); return; }
        change({ video: { file, alt: "" } });
      }} /></label>
      <Button type="button" variant="outline" size="sm" disabled={busy || hasMedia} onClick={() => change({ gif: { url: "", alt: "" } })}>Add GIF</Button>
    </fieldset>
    {images.map((image, index) => <section key={index} aria-label={`Image ${index + 1}`} className="space-y-2 rounded-lg border p-3">
      <AttachmentPreview file={image.file} alt={image.alt} />
      <label className="flex flex-col gap-1 text-sm">Image {index + 1} Alt Text<input value={image.alt} disabled={busy} maxLength={2000} onChange={input => change({ images: images.map((value, position) => position === index ? { ...value, alt: input.target.value } : value) })} className="rounded border bg-background p-2" /></label>
      <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => change({ images: images.filter((_, position) => position !== index) })}>Remove Image {index + 1}</Button>
    </section>)}
    {attachments.video ? <section aria-label="Video Attachment" className="space-y-2 rounded-lg border p-3">
      <AttachmentPreview file={attachments.video.file} alt={attachments.video.alt} video />
      <label className="flex flex-col gap-1 text-sm">Video Alt Text<input value={attachments.video.alt} disabled={busy} maxLength={10000} onChange={input => change({ video: { ...attachments.video!, alt: input.target.value } })} className="rounded border bg-background p-2" /></label>
      <p className="text-xs text-muted-foreground">Alt Text: Up to 1,000 Characters and 10,000 UTF-8 Bytes.</p>
      <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => change({})}>Remove Video</Button>
    </section> : null}
    {attachments.gif ? <section aria-label="GIF Attachment" className="space-y-2 rounded-lg border p-3">
      {!attachmentError && gifValid ? <img src={attachments.gif.url} alt={attachments.gif.alt} className="max-h-56 rounded-lg object-contain" /> : null}
      <label className="flex flex-col gap-1 text-sm">GIF URL<input type="url" placeholder="https://…" value={attachments.gif.url} disabled={busy} onChange={input => change({ gif: { ...attachments.gif!, url: input.target.value } })} className="rounded border bg-background p-2" /></label>
      <label className="flex flex-col gap-1 text-sm">GIF Alt Text<input value={attachments.gif.alt} disabled={busy} maxLength={2000} onChange={input => change({ gif: { ...attachments.gif!, alt: input.target.value } })} className="rounded border bg-background p-2" /></label>
      {!gifValid ? <p role="status" className="text-xs text-destructive">Enter an HTTPS GIF URL.</p> : null}
      <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => change({})}>Remove GIF</Button>
    </section> : null}
    <SocialComposeLinkCard {...link} disabled={busy} />
    {event.destination !== "blog" ? <p aria-live="polite" className={`text-right text-xs ${validText ? "text-muted-foreground" : "text-destructive"}`}>{new RichText({ text: blueskyText }).graphemeLength}/300 Including Title and Hashtags</p> : null}
    <div className="flex flex-wrap items-center justify-between gap-3"><p className="text-xs text-muted-foreground">{event.destination === "blog" ? "Appends a Timestamped Article Entry" : "Title and Hashtags Are Included in Each Post"}</p><Button type="submit" disabled={busy || !valid}>{busy ? "Publishing…" : failure || localError ? "Retry Publish" : "Publish Update"}</Button></div>
    {text.trim() && !validText ? <p role="status" className="text-xs text-destructive">This update exceeds Bluesky’s post limit, including its title and hashtags.</p> : null}
    {attachmentError ? <p role="status" className="text-xs text-destructive">{attachmentError}</p> : null}
    {localError ? <p role="alert" className="text-sm text-destructive">{localError}</p> : null}
  </form>;
}
