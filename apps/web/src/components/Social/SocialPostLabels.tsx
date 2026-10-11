"use client";

import { useState } from "react";
import Link from "next/link";
import type { AppBskyFeedDefs } from "@atproto/api";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { localizedSocialLabel } from "@/lib/socialModerationClient";
import { socialPostLabels } from "@/lib/socialPostLabels";
import type { SocialModerationOpts } from "@/lib/socialModerationTypes";
import { isDevDebugUiEnabled } from "@/lib/appEnv";
import { SocialLabelerAvatar } from "./SocialLabelerAvatar";

export function SocialPostLabels({ post, moderation }: { post: AppBskyFeedDefs.PostView; moderation: SocialModerationOpts }) {
  const [open, setOpen] = useState(false);
  const labels = socialPostLabels(post, moderation);
  if (!labels.length) return null;
  const languages = typeof navigator === "undefined" ? ["en"] : navigator.languages;
  const showDid = isDevDebugUiEnabled();
  return <Dialog open={open} onOpenChange={setOpen}>
    <div className="flex flex-wrap gap-2">
      {labels.slice(0, 2).map(label => <button key={label.key} type="button" className="inline-flex items-center gap-1 rounded-full border px-2 py-1 text-xs text-muted-foreground hover:bg-muted" onClick={event => { event.stopPropagation(); setOpen(true); }}>
        <SocialLabelerAvatar avatar={label.avatar} />{localizedSocialLabel(label.definition, languages).name}
      </button>)}
      {labels.length > 2 ? <button type="button" className="rounded-full border px-2 py-1 text-xs text-muted-foreground hover:bg-muted" onClick={event => { event.stopPropagation(); setOpen(true); }}>+{labels.length - 2} {labels.length === 3 ? "Label" : "Labels"}</button> : null}
    </div>
    <DialogContent className="sm:max-w-lg">
      <DialogTitle>Post Labels</DialogTitle>
      <DialogDescription>Labels applied to this post or its author.</DialogDescription>
      <div className="max-h-[60dvh] space-y-4 overflow-y-auto">
        {labels.map(label => {
          const text = localizedSocialLabel(label.definition, languages);
          return <section key={label.key} className="space-y-1">
            <h3 className="text-sm font-semibold">{text.name}</h3>
            <p className="whitespace-pre-wrap break-words text-sm">{text.description}</p>
            <div className="flex items-center gap-2 pt-1 text-xs text-muted-foreground">
              <SocialLabelerAvatar avatar={label.avatar} className="size-8 bg-muted" />
              <div className="min-w-0 space-y-0.5">
                <p className="break-words">{label.self ? "Applied by the Author" : "Labeler"}: <span className="font-medium text-foreground">{label.displayName || label.handle || (label.self ? "Post Author" : "Unknown Labeler")}</span></p>
                {label.handle ? <p className="break-all">@{label.handle}</p> : null}
                {showDid ? <p className="break-all">{label.source}</p> : null}
              </div>
            </div>
          </section>;
        })}
      </div>
      <Link href="/me/settings" className="text-sm text-primary hover:underline">Manage Labelers</Link>
    </DialogContent>
  </Dialog>;
}
