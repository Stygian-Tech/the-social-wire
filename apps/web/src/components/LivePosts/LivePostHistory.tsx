/* eslint-disable @next/next/no-img-element -- Public PDS blobs retain their original format. */
import Link from "next/link";
import type { PreparedLivePostMedia } from "@/lib/livePosts/livePostMedia";
import { publicLinkUrl } from "@/lib/blueskyExternalEmbed";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";
import { socialPostPageHref } from "@/lib/socialPostNavigation";
import { socialHttpsUrl } from "@/components/Social/socialUrls";
import { SocialRichText } from "@/components/Social/SocialRichText";

function LiveUpdateMedia({ media, authorDid }: { media: PreparedLivePostMedia; authorDid: string }) {
  const pds = socialHttpsUrl(media.pdsUrl);
  const blobUrl = (cid: string) => pds ? `${new URL(pds).origin}/xrpc/com.atproto.sync.getBlob?${new URLSearchParams({ did: authorDid, cid })}` : undefined;
  const gif = media.gif ? socialHttpsUrl(media.gif.url) : undefined;
  const video = media.video ? blobUrl(media.video.blob.ref.$link) : undefined;
  const external = media.external?.external;
  const link = external ? publicLinkUrl(external.uri) : undefined;
  return <div className="space-y-3">
    {media.images?.length ? <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">{media.images.map(image => {
      const src = blobUrl(image.blob.ref.$link);
      return src ? <a key={image.blob.ref.$link} href={src} target="_blank" rel="noopener noreferrer"><img src={src} alt={image.alt} loading="lazy" className="max-h-80 w-full rounded-xl object-contain" /></a> : null;
    })}</div> : null}
    {video ? <video src={video} controls playsInline preload="metadata" aria-label={media.video?.alt || "Update Video"} className="max-h-96 w-full rounded-xl" /> : null}
    {gif ? <img src={gif} alt={media.gif?.alt || "GIF"} loading="lazy" referrerPolicy="no-referrer" className="max-h-80 max-w-full rounded-xl" /> : null}
    {link ? <a href={link} target="_blank" rel="noopener noreferrer" className="block rounded-xl border p-3 text-sm text-primary"><span className="block font-medium">{external?.title || link}</span>{external?.description ? <span className="block text-muted-foreground">{external.description}</span> : null}</a> : null}
  </div>;
}

export function LivePostHistory({ event }: { event: LiveEvent }) {
  const articleUrl = socialHttpsUrl(event.articleUrl);
  return <section aria-label="Event Updates" className="space-y-3">
    <h3 className="text-sm font-semibold">Published Updates</h3>
    {!event.entries.length ? <p className="py-6 text-sm text-muted-foreground">Publish the first update to start this event.</p> : [...event.entries].reverse().map(update => <article key={update.id} className="space-y-3 rounded-2xl border bg-card p-4">
      <div className="flex flex-wrap items-center justify-between gap-2"><time dateTime={update.createdAt} className="text-xs text-muted-foreground">{new Date(update.createdAt).toLocaleString()}</time><span className="text-xs text-muted-foreground">Published</span></div>
      <SocialRichText record={{ $type: "app.bsky.feed.post", text: update.text, createdAt: update.createdAt }} />
      {update.media ? <LiveUpdateMedia media={update.media} authorDid={event.uri.slice(5).split("/")[0]} /> : null}
      <div className="flex flex-wrap gap-4 text-xs text-primary">{update.postRef ? <Link className="hover:underline" href={socialPostPageHref(update.postRef.uri, "/live-post")}>View Bluesky Update</Link> : null}{update.articleRef && articleUrl ? <a className="hover:underline" href={articleUrl} target="_blank" rel="noopener noreferrer">View Article</a> : null}</div>
    </article>)}
  </section>;
}
