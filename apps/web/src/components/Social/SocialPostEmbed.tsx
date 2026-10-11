/* eslint-disable @next/next/no-img-element -- Remote PDS media preserve publisher formats. */
import {
  AppBskyEmbedExternal,
  AppBskyEmbedImages,
  AppBskyEmbedRecord,
  AppBskyEmbedRecordWithMedia,
  AppBskyEmbedVideo,
  AppBskyFeedPost,
  moderateProfile,
  type AppBskyFeedDefs,
  type ModerationOpts,
} from "@atproto/api";
import { moderateSocialPost } from "./socialModeration";
import { SocialVideoPlayer } from "./SocialVideoPlayer";
import { SocialImageGallery } from "./SocialImageGallery";
import { SocialRichText } from "./SocialRichText";
import { socialHttpsUrl, socialPostUrl } from "./socialUrls";
import { socialExternalGif } from "./socialExternalGif";
import { socialGalleryImages } from "./socialGalleryImages";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import Link from "next/link";
import { SocialCashtags } from "./SocialCashtags";

type Embed = AppBskyFeedDefs.PostView["embed"] | AppBskyEmbedRecord.View;

export function SocialPostEmbed({
  embed,
  moderation,
  depth = 0,
  onOpenPost,
}: {
  embed: Embed;
  moderation: ModerationOpts;
  depth?: number;
  onOpenPost?: (post: AppBskyFeedDefs.PostView) => void;
}) {
  if (!embed) return null;
  if (depth > 1)
    return (
      <p className="text-sm text-muted-foreground">
        Nested content unavailable.
      </p>
    );
  if (AppBskyEmbedImages.isView(embed))
    return <SocialImageGallery images={embed.images} />;
  const gallery = socialGalleryImages(embed);
  if (gallery) return <SocialImageGallery images={gallery} />;
  if (AppBskyEmbedExternal.isView(embed)) {
    const href = socialHttpsUrl(embed.external.uri);
    if (!href) return null;
    const gif = socialExternalGif(embed.external);
    if (gif) return <SocialImageGallery images={[gif]} />;
    const thumb = socialHttpsUrl(embed.external.thumb);
    return (
      <a
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        className="block overflow-hidden rounded-xl border bg-muted/30 hover:bg-muted/60"
      >
        {thumb ? (
          <img
            src={thumb}
            alt=""
            loading="lazy"
            referrerPolicy="no-referrer"
            className="block h-auto w-full"
          />
        ) : null}
        <div className="flex flex-col gap-1 p-3">
          <p className="text-sm font-medium">{embed.external.title}</p>
          <p className="line-clamp-3 text-sm text-muted-foreground">
            {embed.external.description}
          </p>
          <p className="text-xs text-muted-foreground">
            {new URL(href).hostname}
          </p>
        </div>
      </a>
    );
  }
  if (AppBskyEmbedVideo.isView(embed)) {
    const src = socialHttpsUrl(embed.playlist);
    if (!src) return null;
    return <SocialVideoPlayer key={src} video={embed} src={src} />;
  }
  if (AppBskyEmbedRecordWithMedia.isView(embed))
    return (
      <div className="flex flex-col gap-3">
        <SocialPostEmbed
          embed={embed.media}
          moderation={moderation}
          onOpenPost={onOpenPost}
          depth={depth}
        />
        <SocialPostEmbed
          // This nested schema reference may omit its optional $type in AppView responses.
          embed={{
            ...embed.record,
            $type: embed.record.$type ?? "app.bsky.embed.record#view",
          }}
          moderation={moderation}
          onOpenPost={onOpenPost}
          depth={depth}
        />
      </div>
    );
  if (!AppBskyEmbedRecord.isView(embed))
    return (
      <p className="text-sm text-muted-foreground">Attachment unavailable.</p>
    );
  const quote = embed.record;
  if (
    !AppBskyEmbedRecord.isViewRecord(quote) ||
    !AppBskyFeedPost.isRecord(quote.value)
  )
    return (
      <p className="rounded-xl border p-3 text-sm text-muted-foreground">
        Quoted content unavailable.
      </p>
    );
  const record = AppBskyFeedPost.validateRecord(quote.value);
  if (!record.success)
    return (
      <p className="text-sm text-muted-foreground">
        Quoted content unavailable.
      </p>
    );
  const post: AppBskyFeedDefs.PostView = {
    uri: quote.uri,
    cid: quote.cid,
    author: quote.author,
    record: record.value,
    labels: quote.labels,
    indexedAt: quote.indexedAt,
    embed: quote.embeds?.[0],
  };
  const decision = moderateSocialPost(post, moderation);
  const content = decision.ui("contentList");
  if (content.filter || content.blur || content.noOverride)
    return (
      <p className="rounded-xl border p-3 text-sm text-muted-foreground">
        Quoted content withheld.
      </p>
    );
  const profile = moderateProfile(quote.author, moderation);
  const identity = profile.ui("displayName");
  const profileList = profile.ui("profileList");
  const media = decision.ui("contentMedia");
  const href = socialPostUrl(quote.uri);
  return (
    <blockquote className="flex flex-col gap-2 rounded-xl border p-3" onClick={onOpenPost ? event => {
      const target = event.target;
      if (target instanceof Element && event.currentTarget.contains(target) && !target.closest('a, button, video, audio') && !window.getSelection()?.toString()) {
        event.stopPropagation(); onOpenPost(post);
      }
    } : undefined}>
      {identity.blur ||
      identity.filter ||
      identity.noOverride ||
      profileList.blur ||
      profileList.filter ||
      profileList.noOverride ? (
        <p className="text-sm text-muted-foreground">Account</p>
      ) : (
        <Link
          href={socialProfilePageHref(quote.author.did)}
          className="text-sm font-medium hover:underline"
        >
          {quote.author.displayName || quote.author.handle}
        </Link>
      )}
      <SocialRichText record={record.value} />
      {!media.blur && !media.filter && !media.noOverride ? <SocialCashtags record={record.value} /> : null}
      {media.blur || media.filter || media.noOverride ? (
        <p className="text-sm text-muted-foreground">Media withheld.</p>
      ) : (
        quote.embeds?.map((child, index) => (
          <SocialPostEmbed
            key={index}
            embed={child}
            moderation={moderation}
            onOpenPost={onOpenPost}
            depth={depth + 1}
          />
        ))
      )}
      {href ? (
        <a
          href={href}
          target="_blank"
          rel="noopener noreferrer"
          onClick={onOpenPost ? event => { event.preventDefault(); event.stopPropagation(); onOpenPost(post); } : undefined}
          className="sr-only focus:not-sr-only focus:text-primary"
        >
          Open Quoted Post
        </a>
      ) : null}
    </blockquote>
  );
}
