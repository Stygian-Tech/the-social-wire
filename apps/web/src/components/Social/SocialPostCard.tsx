"use client";

import { CachedImage } from "@/components/shared/CachedImage";

import type { ReactNode } from "react";
import {
  AppBskyEmbedRecord,
  AppBskyEmbedRecordWithMedia,
  AppBskyFeedDefs,
  AppBskyFeedPost,
  moderateProfile,
  type ModerationOpts,
} from "@atproto/api";
import { moderateSocialPost } from "./socialModeration";
import { SocialPostEmbed } from "./SocialPostEmbed";
import { SocialRichText } from "./SocialRichText";
import { SocialReplyLabel } from "./SocialReplyLabel";
import { SocialActionGlyph } from "./SocialActionGlyph";
import { SocialPostLabels } from "./SocialPostLabels";
import { SocialCashtags } from "./SocialCashtags";
import { SocialPostTimestamp } from "./SocialPostTimestamp";
import { socialHttpsUrl, socialPostUrl } from "./socialUrls";
import { SocialProfileLink } from "./SocialProfileLink";
import { socialReplyMetadata } from "@/lib/socialReplyMetadata";
import { isSocialInteractionHidden } from "@/lib/socialInteractionModeration";

export function SocialPostCard({
  item,
  moderation,
  onOpen,
  actions,
  detailedTimestamp = false,
  onOpenPost,
  embedded = false,
  analyticsSurface = "social-feed",
}: {
  item: AppBskyFeedDefs.FeedViewPost;
  moderation: ModerationOpts;
  onOpen?: () => void;
  actions?: ReactNode;
  detailedTimestamp?: boolean;
  onOpenPost?: (post: AppBskyFeedDefs.PostView) => void;
  embedded?: boolean;
  analyticsSurface?: "social-feed" | "post-viewer" | "messages";
}) {
  const post = item.post;
  const reply = socialReplyMetadata(item);
  if (isSocialInteractionHidden({ ...item, reply }, moderation)) return null;
  const record = AppBskyFeedPost.validateRecord(post.record);
  const decision = moderateSocialPost(post, moderation);
  const content = decision.ui("contentList");
  if (content.filter) return null;
  if (content.blur || content.noOverride)
    return (
      <article className="rounded-2xl border bg-card p-4 text-sm text-muted-foreground">
        Post withheld by your moderation settings.
      </article>
    );
  if (!record.success)
    return (
      <article className="rounded-2xl border bg-card p-4 text-sm text-muted-foreground">
        Post unavailable.
      </article>
    );
  const author = moderateProfile(post.author, moderation);
  const avatar = author.ui("avatar");
  const identity = author.ui("displayName");
  const media = decision.ui("contentMedia");
  const href = socialPostUrl(post.uri);
  const image =
    avatar.blur || avatar.filter || avatar.noOverride
      ? undefined
      : socialHttpsUrl(post.author.avatar);
  const name =
    identity.blur || identity.filter || identity.noOverride
      ? "Account"
      : post.author.displayName || post.author.handle;
  const repost = AppBskyFeedDefs.isReasonRepost(item.reason)
    ? item.reason.by
    : undefined;
  const reposter = repost ? moderateProfile(repost, moderation) : undefined;
  const reposterIdentity = reposter?.ui("displayName");
  const reposterList = reposter?.ui("profileList");
  const quotedRecord: AppBskyEmbedRecord.View["record"] | undefined = AppBskyEmbedRecord.isView(post.embed)
    ? post.embed.record
    : AppBskyEmbedRecordWithMedia.isView(post.embed)
      ? post.embed.record.record
      : undefined;
  const quotedPost = AppBskyEmbedRecord.validateViewRecord(quotedRecord);
  const hasQuotedPost =
    !media.blur && !media.filter && !media.noOverride &&
    quotedPost.success && AppBskyFeedPost.isRecord(quotedPost.value.value);
  const timestamp = Number.isNaN(Date.parse(record.value.createdAt)) ? post.indexedAt : record.value.createdAt;
  const date = new Date(timestamp);
  return (
    <article data-analytics-subject={post.uri} data-analytics-surface={analyticsSurface} className={`flex min-w-0 shrink-0 flex-col gap-3 text-card-foreground ${onOpen ? "cursor-pointer" : ""} ${embedded ? "" : "rounded-2xl border bg-card p-4"}`}
      onClick={onOpen ? event => {
        const target = event.target;
        if (target instanceof Element && event.currentTarget.contains(target) && !target.closest('a, button, input, video, audio') && !window.getSelection()?.toString()) { event.stopPropagation(); onOpen(); }
      } : undefined}>
      {repost ? (
        <p className="flex items-center gap-2 text-xs text-muted-foreground">
          <SocialActionGlyph reason="repost" /><span>
          Reposted{" "}
          {reposterList?.filter ||
          reposterList?.blur ||
          reposterList?.noOverride ||
          reposterIdentity?.blur ||
          reposterIdentity?.filter ||
          reposterIdentity?.noOverride
            ? "by an account"
            : <>by <SocialProfileLink actor={repost.did} className="hover:underline">{repost.displayName || repost.handle}</SocialProfileLink></>}
          </span></p>
      ) : null}
      {reply ? (
        <SocialReplyLabel reply={reply} moderation={moderation} />
      ) : null}
      {hasQuotedPost ? (
        <p className="flex items-center gap-2 text-xs text-muted-foreground">
          <SocialActionGlyph reason="quote" />
          <span>Quoted Post</span>
        </p>
      ) : null}
      <div className="flex items-center gap-3">
        <SocialProfileLink actor={post.author.did} aria-label={`Open Profile: ${name}`} className="inline-flex shrink-0 rounded-full focus-visible:outline-2 focus-visible:outline-ring">{image ? (
          <CachedImage
            src={image}
            alt=""
            width={40}
            height={40}
            loading="lazy"
            className="size-10 shrink-0 rounded-full object-cover"
          />
        ) : (
          <span
            className="size-10 shrink-0 rounded-full bg-muted"
            aria-hidden="true"
          />
        )}</SocialProfileLink>
        <div className="min-w-0 flex-1">
          <SocialProfileLink
            actor={post.author.did}
            className="block truncate text-sm font-semibold hover:underline"
          >
            {name}
          </SocialProfileLink>
          {!identity.blur && !identity.filter && !identity.noOverride ? (
            <SocialProfileLink actor={post.author.did} className="block truncate text-xs text-muted-foreground hover:underline">
              @{post.author.handle}
            </SocialProfileLink>
          ) : null}
        </div>
        {!detailedTimestamp ? <SocialPostTimestamp timestamp={timestamp} /> : null}
      </div>
      <SocialPostLabels post={post} moderation={moderation} />
      <SocialRichText record={record.value} />
      {!media.blur && !media.filter && !media.noOverride ? <SocialCashtags record={record.value} /> : null}
      {post.embed ? (
        media.blur || media.filter || media.noOverride ? (
          <p className="text-sm text-muted-foreground">Media withheld.</p>
        ) : (
          <SocialPostEmbed embed={post.embed} moderation={moderation} onOpenPost={onOpenPost} />
        )
      ) : null}
      {detailedTimestamp && !Number.isNaN(date.getTime()) ? (
        <time className="text-xs text-muted-foreground" dateTime={date.toISOString()}>{date.toLocaleString()}</time>
      ) : null}
      {href ? <a href={href} aria-label="Open Post" onClick={onOpen ? event => { event.preventDefault(); onOpen(); } : undefined} className="sr-only focus:not-sr-only focus:rounded focus:px-2 focus:text-primary">Open Post</a> : null}
      {actions}
    </article>
  );
}
