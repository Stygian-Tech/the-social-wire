import Link from "next/link";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";
import { socialPostPageHref } from "@/lib/socialPostNavigation";
import { socialHttpsUrl } from "@/components/Social/socialUrls";
import { SocialRichText } from "@/components/Social/SocialRichText";

export function LivePostHistory({ event }: { event: LiveEvent }) {
  const articleUrl = socialHttpsUrl(event.articleUrl);
  return <section aria-label="Event Updates" className="space-y-3">
    <h3 className="text-sm font-semibold">Published Updates</h3>
    {!event.entries.length ? <p className="py-6 text-sm text-muted-foreground">Publish the first update to start this event.</p> : [...event.entries].reverse().map(update => <article key={update.id} className="space-y-3 rounded-2xl border bg-card p-4">
      <div className="flex flex-wrap items-center justify-between gap-2"><time dateTime={update.createdAt} className="text-xs text-muted-foreground">{new Date(update.createdAt).toLocaleString()}</time><span className="text-xs text-muted-foreground">Published</span></div>
      <SocialRichText record={{ $type: "app.bsky.feed.post", text: update.text, createdAt: update.createdAt }} />
      <div className="flex flex-wrap gap-4 text-xs text-primary">{update.postRef ? <Link className="hover:underline" href={socialPostPageHref(update.postRef.uri, "/live-post")}>View Bluesky Update</Link> : null}{update.articleRef && articleUrl ? <a className="hover:underline" href={articleUrl} target="_blank" rel="noopener noreferrer">View Article</a> : null}</div>
    </article>)}
  </section>;
}
