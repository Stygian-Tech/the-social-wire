"use client";

import type { AppBskyDraftDefs } from "@atproto/api";
import { Button } from "@/components/ui/button";

export function SocialDraftRow({ draft, onOpen, onDelete, disabled }: {
  draft: AppBskyDraftDefs.DraftView;
  onOpen: () => void;
  onDelete: () => void;
  disabled: boolean;
}) {
  const posts = draft.draft.posts;
  const snippet = posts.map(post => post.text).filter(text => text.trim()).join("\n").slice(0, 280) || "Untitled Draft";
  const hasLocalMedia = posts.some(post => !!(post.embedImages?.length || post.embedVideos?.length || (post as unknown as { embedGallery?: unknown }).embedGallery));
  const updated = new Date(draft.updatedAt);
  return <article className="rounded-xl border bg-card p-4">
    <button type="button" className="w-full space-y-2 text-left disabled:opacity-50" disabled={disabled} onClick={onOpen} aria-label={`Open Draft: ${snippet}`}>
      <p className="line-clamp-3 whitespace-pre-wrap break-words text-sm">{snippet}</p>
      <p className="text-xs text-muted-foreground">{posts.length} {posts.length === 1 ? "Post" : "Posts"} · <time dateTime={draft.updatedAt}>{Number.isNaN(updated.getTime()) ? "Unknown Update Time" : updated.toLocaleString()}</time></p>
      {hasLocalMedia ? <p className="text-xs text-muted-foreground">Media is available on the original device. Open this draft there to restore attachments.</p> : null}
    </button>
    <div className="mt-3 flex justify-end"><Button variant="outline" size="sm" disabled={disabled} onClick={onDelete}>Delete Draft</Button></div>
  </article>;
}
