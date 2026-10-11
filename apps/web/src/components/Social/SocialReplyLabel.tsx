"use client";

import { AppBskyFeedDefs, moderateProfile, type ModerationOpts } from "@atproto/api";
import { moderateSocialPost } from "./socialModeration";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import Link from "next/link";

export function SocialReplyLabel({ reply, moderation }: { reply: NonNullable<AppBskyFeedDefs.FeedViewPost["reply"]>; moderation: ModerationOpts }) {
  const parent = reply.parent;
  if (!AppBskyFeedDefs.isPostView(parent)) return <p className="text-xs text-muted-foreground">Replying To an unavailable post</p>;
  const content = moderateSocialPost(parent, moderation).ui("contentList");
  const identity = moderateProfile(parent.author, moderation).ui("displayName");
  const withheld = [content, identity].some(ui => ui.filter || ui.blur || ui.noOverride);
  return <p className="text-xs text-muted-foreground">Replying To{withheld ? " a withheld post" : <> <Link href={socialProfilePageHref(parent.author.did)} className="break-all hover:underline">@{parent.author.handle}</Link></>}</p>;
}
