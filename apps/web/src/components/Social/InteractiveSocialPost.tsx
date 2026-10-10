"use client";

import { useState } from "react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { SocialPostCard } from "./SocialPostCard";
import { SocialPostActions } from "./SocialPostActions";
import { SocialPostDialog } from "./SocialPostDialog";

export function InteractiveSocialPost({ item, moderation }: { item: AppBskyFeedDefs.FeedViewPost; moderation: ModerationOpts }) {
  const [open, setOpen] = useState(false);
  return <>
    <SocialPostCard item={item} moderation={moderation} onOpen={() => setOpen(true)} actions={<SocialPostActions post={item.post} moderation={moderation} onOpen={() => setOpen(true)} />} />
    {open ? <SocialPostDialog item={item} moderation={moderation} open={open} onOpenChange={setOpen} /> : null}
  </>;
}
