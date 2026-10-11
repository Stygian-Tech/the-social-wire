"use client";

import { useState } from "react";
import type { ModerationOpts } from "@atproto/api";
import { SocialPostDialog } from "./SocialPostDialog";

export function SocialPostLink({ uri, moderation }: { uri: string; moderation: ModerationOpts }) {
  const [open, setOpen] = useState(false);
  return <>
    <button type="button" className="text-left text-sm text-primary hover:underline" onClick={() => setOpen(true)}>Open Post</button>
    {open ? <SocialPostDialog uri={uri} moderation={moderation} open onOpenChange={setOpen} /> : null}
  </>;
}
