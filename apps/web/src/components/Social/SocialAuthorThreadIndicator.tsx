"use client";

import { useEffect, useRef, useState } from "react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { MessagesSquare } from "lucide-react";
import { useBlueskyPostThread } from "@/hooks/useBlueskyPostThread";
import { socialAuthorThread, socialAuthorThreadUri } from "@/lib/socialAuthorThread";

/** Visible candidates share the account-scoped conversation cache. */
export function SocialAuthorThreadIndicator({ item, moderation, onOpen, thread }: { item: AppBskyFeedDefs.FeedViewPost; moderation: ModerationOpts; onOpen: (uri: string) => void; thread?: AppBskyFeedDefs.ThreadViewPost }) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);
  const uri = socialAuthorThreadUri(item);
  useEffect(() => {
    if (!uri || thread || !ref.current || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) { setVisible(true); observer.disconnect(); }
    });
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, [uri, thread]);
  const query = useBlueskyPostThread(visible && !thread ? uri : undefined, moderation);
  const summary = thread ? socialAuthorThread(thread, moderation) : !query.isError ? socialAuthorThread(query.data?.thread, moderation) : undefined;
  if (!uri && !thread) return null;
  return <div ref={ref} className={summary && summary.count > 1 ? undefined : "absolute size-px overflow-hidden pointer-events-none"}>{summary && summary.count > 1 ? <button type="button" className="flex min-h-8 items-center gap-1.5 rounded text-xs font-medium text-muted-foreground hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring" title={summary.partial ? "At least this many OP posts are available; some replies are missing or withheld." : "Original post and continuous self-replies by OP"} aria-label={`Open OP Thread (${summary.partial ? "At Least " : ""}${summary.count} Posts)`} onClick={() => onOpen(thread?.post.uri ?? uri!)}><MessagesSquare aria-hidden="true" className="size-3.5" /><span>OP Thread · {summary.count}{summary.partial ? "+" : ""} Posts</span></button> : null}</div>;
}
