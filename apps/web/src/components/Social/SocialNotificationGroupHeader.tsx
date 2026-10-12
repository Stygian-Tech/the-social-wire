"use client";

import Link from "next/link";
import { Heart, MessageCircle, Quote, Repeat2, type LucideIcon } from "lucide-react";
import { moderateProfile, type ModerationOpts } from "@atproto/api";
import { Avatar } from "@/components/shared/Avatar";
import type { SocialNotificationGroup } from "@/lib/socialNotificationGrouping";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";
import { socialHttpsUrl } from "./socialUrls";

const reasons: Record<string, string> = { like: "Liked Your Post", repost: "Reposted Your Post", follow: "Followed You", mention: "Mentioned You", reply: "Replied to Your Post", quote: "Quoted Your Post", "starterpack-joined": "Joined Your Starter Pack", verified: "Verified Your Account", unverified: "Removed Your Verification", "like-via-repost": "Liked a Post You Reposted", "repost-via-repost": "Reposted a Post You Reposted", "subscribed-post": "Posted an Update", "contact-match": "Joined Bluesky" };

const actionGlyphs: Record<string, { icon: LucideIcon; className: string }> = {
  like: { icon: Heart, className: "text-rose-600 dark:text-rose-400" },
  "like-via-repost": { icon: Heart, className: "text-rose-600 dark:text-rose-400" },
  reply: { icon: MessageCircle, className: "text-muted-foreground" },
  repost: { icon: Repeat2, className: "text-green-600 dark:text-green-400" },
  "repost-via-repost": { icon: Repeat2, className: "text-green-600 dark:text-green-400" },
  quote: { icon: Quote, className: "text-muted-foreground" },
};

export function SocialNotificationGroupHeader({ group, moderation }: { group: SocialNotificationGroup; moderation: ModerationOpts }) {
  const actionGlyph = actionGlyphs[group.latest.reason];
  const ActionIcon = actionGlyph?.icon;
  const names = group.authors.map(author => {
    const decision = moderateProfile(author, moderation).ui("displayName");
    return decision.filter || decision.blur || decision.noOverride ? author.handle : author.displayName || author.handle;
  });
  const summary = `${names.slice(0, 2).join(" and ")}${names.length > 2 ? ` + ${names.length - 2}` : ""}`;
  const avatar = (index: number) => {
    const author = group.authors[index]!;
    const decision = moderateProfile(author, moderation).ui("avatar");
    return <Avatar key={author.did} src={decision.filter || decision.blur || decision.noOverride ? undefined : socialHttpsUrl(author.avatar)} alt="" size={32} className="shrink-0 ring-2 ring-card" />;
  };
  return <div className="space-y-2">
    <div className="flex items-start gap-3">
      <div className="flex shrink-0 -space-x-2">{group.authors.slice(0, 2).map((_, index) => avatar(index))}</div>
      <div className="min-w-0 flex-1">
        {group.authors.length > 1 ? <details className="group">
          <summary aria-label={`Show People: ${summary}`} className="cursor-pointer break-words font-semibold">{summary}</summary>
          <ul aria-label="People" className="mt-2 space-y-2">
            {group.authors.map((author, index) => <li key={author.did} className="flex items-center gap-2">{avatar(index)}<Link href={socialProfilePageHref(author.did, "/social/notifications")} className="min-w-0 break-words text-sm hover:underline">{names[index]}</Link></li>)}
          </ul>
        </details> : <Link href={socialProfilePageHref(group.latest.author.did, "/social/notifications")} className="break-words font-semibold hover:underline">{summary}</Link>}
      </div>
      {!group.isRead ? <span className="shrink-0 text-xs font-semibold text-primary">Unread</span> : null}
    </div>
    <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
      <p className="flex items-center gap-2 text-sm">
        {ActionIcon ? <ActionIcon aria-hidden="true" className={`size-4 shrink-0 ${actionGlyph?.className}`} /> : null}
        {reasons[group.latest.reason] ?? "Sent a Notification"}
      </p>
      <time dateTime={group.latest.indexedAt} className="text-xs text-muted-foreground">{new Date(group.latest.indexedAt).toLocaleString()}</time>
    </div>
  </div>;
}
