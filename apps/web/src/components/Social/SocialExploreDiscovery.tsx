"use client";

import Link from "next/link";
import { moderateFeedGenerator, type ModerationOpts } from "@atproto/api";
import { Button } from "@/components/ui/button";
import { Avatar } from "@/components/shared/Avatar";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { useSocialExploreDiscovery } from "@/hooks/useSocialExploreDiscovery";
import { safeSocialFeedAvatarUrl, socialFeedHref, type SocialFeed } from "@/lib/blueskySocialClient";
import { socialTrendingSearch } from "@/lib/socialExploreDiscoveryClient";
import { socialDiscoveryErrorMessage } from "@/lib/blueskySocialDiscoveryClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialExploreDiscovery({ moderation, savedFeeds, search, enabled }: { moderation?: ModerationOpts; savedFeeds: SocialFeed[]; search: (query: string) => void; enabled: boolean }) {
  const { topics, feeds, save } = useSocialExploreDiscovery(moderation, enabled);
  if (!enabled) return null;
  const visibleFeeds = !feeds.isError && moderation ? (feeds.data ?? []).filter(feed => {
    const decision = moderateFeedGenerator(feed, moderation);
    return (["contentList", "contentView", "profileList", "displayName"] as const).every(context => { const ui = decision.ui(context); return !ui.filter && !ui.blur && !ui.noOverride; });
  }) : [];
  const topicRows = !topics.isError ? Array.from(new Map([...(topics.data?.topics ?? []), ...(topics.data?.suggested ?? [])].map(topic => [socialTrendingSearch(topic), topic])).values()).slice(0, 10) : [];
  const saveError = save.isError ? socialDiscoveryErrorMessage(save.error, "Explore") : undefined;
  return <>
    <section aria-labelledby="explore-trending" className={`${floatingGlassClasses} flex flex-col gap-3 p-3 sm:p-4`}>
      <h2 id="explore-trending" className="text-lg font-semibold">Trending Topics</h2>
      {topics.isPending ? <p role="status" className="text-sm text-muted-foreground">Loading trending topics…</p> : topics.isError ? <div role="alert"><p className="text-sm text-muted-foreground">{socialDiscoveryErrorMessage(topics.error, "Explore")}</p><Button variant="outline" onClick={() => { void topics.refetch(); }}>Retry Topics</Button></div> : topicRows.length ? <ul aria-label="Trending Topics" className="flex flex-col divide-y divide-border">{topicRows.map(topic => <li key={socialTrendingSearch(topic)} className="py-1"><Button variant="ghost" className="h-auto w-full flex-col items-start gap-1 whitespace-normal break-words rounded-lg px-3 py-2 text-left" onClick={() => search(socialTrendingSearch(topic))}><span className="font-medium">{topic.displayName || topic.topic}</span>{topic.description?.trim() ? <span className="whitespace-pre-wrap text-sm font-normal text-muted-foreground">{topic.description.trim()}</span> : null}</Button></li>)}</ul> : <p className="text-sm text-muted-foreground">No trending topics to show right now.</p>}
    </section>
    <section aria-labelledby="explore-feeds" className={`${floatingGlassClasses} flex flex-col gap-3 p-3 sm:p-4`}>
      <h2 id="explore-feeds" className="text-lg font-semibold">Recommended Feeds</h2>
      {!moderation ? <p className="text-sm text-muted-foreground">Feed recommendations require your moderation settings.</p> : feeds.isPending ? <p role="status" className="text-sm text-muted-foreground">Loading recommended feeds…</p> : feeds.isError ? <div role="alert"><p className="text-sm text-muted-foreground">{socialDiscoveryErrorMessage(feeds.error, "Explore")}</p><Button variant="outline" onClick={() => { void feeds.refetch(); }}>Retry Feeds</Button></div> : visibleFeeds.length ? visibleFeeds.map(feed => {
        const saved = savedFeeds.find(item => item.uri === feed.uri);
        const avatar = moderateFeedGenerator(feed, moderation).ui("avatar");
        const avatarSource = avatar.filter || avatar.blur || avatar.noOverride ? undefined : safeSocialFeedAvatarUrl(feed.avatar);
        return <article key={feed.uri} className="flex min-w-0 flex-col gap-3 rounded-2xl border bg-card p-4"><div className="flex min-w-0 items-center gap-3"><Avatar src={avatarSource} alt="" size={40} className="shrink-0" /><div className="min-w-0"><h3 className="break-words font-semibold">{feed.displayName}</h3><p className="break-all text-sm text-muted-foreground">By @{feed.creator.handle}</p></div></div>{feed.description ? <p className="whitespace-pre-wrap break-words text-sm">{feed.description}</p> : null}<div className="flex flex-wrap gap-2"><Link className="rounded-md border px-3 py-2 text-sm hover:bg-muted" href={socialFeedHref({ kind: "feed", uri: feed.uri, name: feed.displayName, pinned: saved?.pinned ?? false })}>Open Feed</Link><Button variant="outline" disabled={!!saved || save.isPending} onClick={() => save.mutate(feed.uri)}>{saved ? "Added" : "Add Feed"}</Button></div></article>;
      }) : <p className="text-sm text-muted-foreground">No recommended feeds to show right now.</p>}
      <Link className="self-start text-sm underline underline-offset-4" href="/social/feeds">Browse All Feeds</Link>
      {saveError ? <div role="alert" className="flex flex-col items-start gap-2"><p className="text-sm text-muted-foreground">{saveError}</p>{saveError === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => save.reset()}>Dismiss</Button>}</div> : null}
    </section>
  </>;
}
