"use client";

import { moderateProfile, type ModerationOpts } from "@atproto/api";
import { Avatar } from "@/components/shared/Avatar";
import type { SocialNotificationGroup } from "@/lib/socialNotificationGrouping";
import { SocialProfileLink } from "./SocialProfileLink";
import { socialHttpsUrl } from "./socialUrls";
import { SocialActionGlyph } from "./SocialActionGlyph";

const reasons: Record<string, string> = { like: "Liked Your Post", repost: "Reposted Your Post", follow: "Followed You", mention: "Mentioned You", reply: "Replied to Your Post", quote: "Quoted Your Post", "starterpack-joined": "Joined Your Starter Pack", verified: "Verified Your Account", unverified: "Removed Your Verification", "like-via-repost": "Liked a Post You Reposted", "repost-via-repost": "Reposted a Post You Reposted", "subscribed-post": "Posted an Update", "contact-match": "Joined Bluesky" };

export function SocialNotificationGroupHeader({ group, moderation }: { group: SocialNotificationGroup; moderation: ModerationOpts }) {
  const names = group.authors.map(author => {
    const decision = moderateProfile(author, moderation).ui("displayName");
    return decision.filter || decision.blur || decision.noOverride ? author.handle : author.displayName || author.handle;
  });
  const summary = `${names.slice(0, 2).join(" and ")}${names.length > 2 ? ` + ${names.length - 2}` : ""}`;
  const avatar = (index: number) => {
    const author = group.authors[index]!;
    const decision = moderateProfile(author, moderation).ui("avatar");
    return <SocialProfileLink key={author.did} actor={author.did} returnTo="/social/notifications" aria-label={`Open Profile: ${names[index]}`} className="shrink-0 rounded-full"><Avatar src={decision.filter || decision.blur || decision.noOverride ? undefined : socialHttpsUrl(author.avatar)} alt="" size={32} className="shrink-0 ring-2 ring-card" /></SocialProfileLink>;
  };
  return <div className="flex flex-col gap-2">
    <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-xs text-muted-foreground">
      <p className="flex items-center gap-1.5">
        <SocialActionGlyph reason={group.latest.reason} />
        {reasons[group.latest.reason] ?? "Sent a Notification"}
      </p>
      <time dateTime={group.latest.indexedAt}>{new Date(group.latest.indexedAt).toLocaleString()}</time>
    </div>
    <div className="flex items-start gap-3">
      <div className="flex shrink-0 -space-x-2">{group.authors.slice(0, 2).map((_, index) => avatar(index))}</div>
      <div className="min-w-0 flex-1">
        {group.authors.length > 1 ? <details className="group">
          <summary aria-label={`Show People: ${summary}`} className="cursor-pointer break-words font-semibold">{summary}</summary>
          <ul aria-label="People" className="mt-2 space-y-2">
            {group.authors.map((author, index) => <li key={author.did} className="flex items-center gap-2">{avatar(index)}<SocialProfileLink actor={author.did} returnTo="/social/notifications" className="min-w-0 break-words text-sm hover:underline">{names[index]}</SocialProfileLink></li>)}
          </ul>
        </details> : <SocialProfileLink actor={group.latest.author.did} returnTo="/social/notifications" className="break-words font-semibold hover:underline">{summary}</SocialProfileLink>}
      </div>
      {!group.isRead ? <span className="shrink-0 text-xs font-semibold text-primary">Unread</span> : null}
    </div>
  </div>;
}
