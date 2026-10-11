"use client";

import { AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { useBlueskyPostThread } from "@/hooks/useBlueskyPostThread";
import { useBlueskyProfile } from "@/hooks/useBlueskyProfile";
import { isSocialProfileActor } from "@/lib/socialProfileNavigation";
import { isSocialPostUri } from "@/lib/socialPostNavigation";
import { SocialPostCard } from "./SocialPostCard";
import { moderateSocialPost } from "./socialModeration";
import { useSocialPostNavigation } from "@/hooks/useSocialPostNavigation";

export function chatPostReference(text: string): { actor: string; rkey: string } | undefined {
  for (const match of text.matchAll(/https:\/\/bsky\.app\/profile\/[^\s<>"']+/g)) {
    try {
      const url = new URL(match[0].replace(/[.,!?;]+$/, ""));
      if (url.search || url.hash || url.username || url.password) continue;
      const parts = /^\/profile\/([^/]+)\/post\/([^/]+)$/.exec(url.pathname);
      if (!parts) continue;
      const actor = decodeURIComponent(parts[1]);
      const rkey = decodeURIComponent(parts[2]);
      if (isSocialProfileActor(actor) && /^[a-zA-Z0-9._~:-]{1,512}$/.test(rkey) && rkey !== "." && rkey !== "..") return { actor, rkey };
    } catch { /* Invalid links remain plain message text. */ }
  }
}

export function SocialChatPostPreview({ text, moderation }: { text: string; moderation?: ModerationOpts }) {
  const reference = chatPostReference(text);
  return reference ? <ResolvedPostPreview reference={reference} moderation={moderation} /> : null;
}

function ResolvedPostPreview({ reference, moderation }: { reference: { actor: string; rkey: string }; moderation?: ModerationOpts }) {
  const navigation = useSocialPostNavigation();
  const profile = useBlueskyProfile(reference && !reference.actor.startsWith("did:") ? reference.actor : undefined, moderation);
  const actor = reference?.actor.startsWith("did:") ? reference.actor : !profile.isError ? profile.data?.did : undefined;
  const candidate = actor && reference ? `at://${actor}/app.bsky.feed.post/${reference.rkey}` : undefined;
  const uri = isSocialPostUri(candidate) ? candidate : undefined;
  const query = useBlueskyPostThread(uri, moderation);
  const thread = !query.isError && moderation ? query.data?.thread : undefined;
  if (!reference) return null;
  if (!moderation || query.isPending || (!actor && profile.isPending)) return <p className="text-xs text-muted-foreground">Post preview unavailable.</p>;
  const post = AppBskyFeedDefs.isThreadViewPost(thread) ? (thread as AppBskyFeedDefs.ThreadViewPost).post : undefined;
  if (!post) return <p className="text-xs text-muted-foreground">Post preview unavailable.</p>;
  const content = moderateSocialPost(post, moderation).ui("contentList");
  if (content.filter || content.blur || content.noOverride) return <p className="text-xs text-muted-foreground">Post preview withheld.</p>;
  return <div className="mt-1 min-w-0"><SocialPostCard item={{ post }} moderation={moderation} onOpen={() => navigation.openPost(post.uri)} onOpenPost={post => navigation.openPost(post.uri)} /></div>;
}
