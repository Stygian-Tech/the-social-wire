"use client";

/* eslint-disable @next/next/no-img-element -- Remote PDS media preserve publisher formats. */
import type { ReactNode } from "react";
import {
  AppBskyFeedDefs,
  AppBskyFeedPost,
  moderateProfile,
  type ModerationOpts,
} from "@atproto/api";
import { moderateSocialPost } from "./socialModeration";
import { SocialPostEmbed } from "./SocialPostEmbed";
import { SocialRichText } from "./SocialRichText";
import { SocialPostTimestamp } from "./SocialPostTimestamp";
import { socialHttpsUrl, socialPostUrl, socialProfileUrl } from "./socialUrls";

export function SocialPostCard({
  item,
  moderation,
  onOpen,
  actions,
  detailedTimestamp = false,
}: {
  item: AppBskyFeedDefs.FeedViewPost;
  moderation: ModerationOpts;
  onOpen?: () => void;
  actions?: ReactNode;
  detailedTimestamp?: boolean;
}) {
  const post = item.post;
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
  const timestamp = Number.isNaN(Date.parse(record.value.createdAt)) ? post.indexedAt : record.value.createdAt;
  const date = new Date(timestamp);
  return (
    <article className="flex min-w-0 shrink-0 flex-col gap-3 rounded-2xl border bg-card p-4 text-card-foreground"
      onClick={onOpen ? event => {
        const target = event.target;
        if (target instanceof Element && !target.closest('a, button, input, video, audio, [role="dialog"]') && !window.getSelection()?.toString()) onOpen();
      } : undefined}>
      {repost ? (
        <p className="text-xs text-muted-foreground">
          Reposted{" "}
          {reposterList?.filter ||
          reposterList?.blur ||
          reposterList?.noOverride ||
          reposterIdentity?.blur ||
          reposterIdentity?.filter ||
          reposterIdentity?.noOverride
            ? "by an account"
            : `by ${repost.displayName || repost.handle}`}
        </p>
      ) : null}
      {item.reply ? (
        <p className="text-xs text-muted-foreground">Reply</p>
      ) : null}
      <div className="flex items-center gap-3">
        {image ? (
          <img
            src={image}
            alt=""
            width={40}
            height={40}
            loading="lazy"
            referrerPolicy="no-referrer"
            className="size-10 shrink-0 rounded-full object-cover"
          />
        ) : (
          <span
            className="size-10 shrink-0 rounded-full bg-muted"
            aria-hidden="true"
          />
        )}
        <div className="min-w-0 flex-1">
          <a
            href={socialProfileUrl(post.author.did)}
            target="_blank"
            rel="noopener noreferrer"
            className="block truncate text-sm font-semibold hover:underline"
          >
            {name}
          </a>
          {!identity.blur && !identity.filter && !identity.noOverride ? (
            <p className="truncate text-xs text-muted-foreground">
              @{post.author.handle}
            </p>
          ) : null}
        </div>
        {!detailedTimestamp ? <SocialPostTimestamp timestamp={timestamp} /> : null}
      </div>
      <SocialRichText record={record.value} />
      {post.embed ? (
        media.blur || media.filter || media.noOverride ? (
          <p className="text-sm text-muted-foreground">Media withheld.</p>
        ) : (
          <SocialPostEmbed embed={post.embed} moderation={moderation} />
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
