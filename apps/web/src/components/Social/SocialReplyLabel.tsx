"use client";

import { AppBskyFeedDefs, moderateProfile, type ModerationOpts } from "@atproto/api";
import { moderateSocialPost } from "./socialModeration";
import { SocialProfileLink } from "./SocialProfileLink";
import { SocialActionGlyph } from "./SocialActionGlyph";

export function SocialReplyLabel({ reply, moderation }: { reply: NonNullable<AppBskyFeedDefs.FeedViewPost["reply"]>; moderation: ModerationOpts }) {
  const parent = reply.parent;
  if (!AppBskyFeedDefs.isPostView(parent)) return <p className="flex items-center gap-2 text-xs text-muted-foreground"><SocialActionGlyph reason="reply" /><span>{AppBskyFeedDefs.isNotFoundPost(parent) && parent.notFound === true ? "Replying To an unavailable post" : "Reply"}</span></p>;
  const content = moderateSocialPost(parent, moderation).ui("contentList");
  const identity = moderateProfile(parent.author, moderation).ui("displayName");
  const withheld = [content, identity].some(ui => ui.filter || ui.blur || ui.noOverride);
  return <p className="flex items-center gap-2 text-xs text-muted-foreground"><SocialActionGlyph reason="reply" /><span>Replying To{withheld ? " a withheld post" : <> <SocialProfileLink actor={parent.author.did} className="break-all hover:underline">@{parent.author.handle}</SocialProfileLink></>}</span></p>;
}
