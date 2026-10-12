"use client";

import { useCallback, useState } from "react";
import { useBrandAccounts } from "@/hooks/useBrandAccounts";
import { includeBrandNotifications, setIncludeBrandNotifications } from "@/lib/brandAccounts/brandNotificationPreferences";
import { BrandNotificationSections } from "./BrandNotificationSections";
import { moderateNotification } from "@atproto/api";
import { useQueryClient } from "@tanstack/react-query";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialNotifications, useSocialNotificationUnread, useMarkSocialNotificationsSeen } from "@/hooks/useSocialDiscovery";
import { notificationFeedItem, notificationIdentity, notificationPostUri, socialDiscoveryErrorMessage } from "@/lib/blueskySocialDiscoveryClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPostLink } from "./SocialPostLink";
import { InteractiveSocialPost } from "./InteractiveSocialPost";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialTimelineSkeleton } from "./SocialTimelineSkeleton";
import { moderateSocialPost } from "./socialModeration";
import { groupSocialNotifications } from "@/lib/socialNotificationGrouping";
import { SocialNotificationGroupHeader } from "./SocialNotificationGroupHeader";

export function SocialNotifications() {
  const { session } = useAuth();
  return <SocialNotificationsViewer key={session?.did ?? "signed-out"} />;
}

function SocialNotificationsViewer() {
  const { session } = useAuth();
  const brandAccounts = useBrandAccounts(session?.did ?? "");
  const [includeBrands, setIncludeBrands] = useState(() => includeBrandNotifications(session?.did ?? ""));
  const [brandUnread, setBrandUnread] = useState<Record<string, number | undefined>>({});
  const reportBrandUnread = useCallback((did: string, count: number | undefined) => setBrandUnread(previous => previous[did] === count ? previous : { ...previous, [did]: count }), []);
  function changeIncludeBrands(value: boolean) {
    setIncludeBrands(value);
    if (session) setIncludeBrandNotifications(session.did, value);
  }
  const catalog = useBlueskySocialCatalog();
  const availableModeration = catalog.data?.moderation;
  const moderation = !catalog.isError && availableModeration?.userDid === session?.did ? availableModeration : undefined;
  const notifications = useSocialNotifications(moderation);
  const unread = useSocialNotificationUnread(!!moderation);
  const markSeen = useMarkSocialNotificationsSeen();
  const queryClient = useQueryClient();
  const error = catalog.isError ? socialDiscoveryErrorMessage(catalog.error, "Notifications") : notifications.isError ? socialDiscoveryErrorMessage(notifications.error, "Notifications") : undefined;
  const pages = notifications.data?.pages ?? [];
  const posts = new Map(pages.flatMap(page => page.posts).map(post => [post.uri, post]));
  const seen = new Set<string>();
  const rows = moderation ? pages.flatMap(page => page.notifications).filter(notification => {
    const key = notificationIdentity(notification);
    const decision = moderateNotification(notification, moderation).ui("contentList");
    const post = posts.get(notificationPostUri(notification) ?? "");
    if (seen.has(key) || decision.filter || decision.blur || decision.noOverride || (post && moderateSocialPost(post, moderation).ui("contentList").filter)) return false;
    seen.add(key); return true;
  }) : [];
  const groups = groupSocialNotifications(rows);
  async function refresh() {
    const settings = await catalog.refetch();
    if (!settings.isError && session) await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["blueskySocial", session.did, "notifications"] }),
      queryClient.invalidateQueries({ queryKey: ["blueskySocial", session.did, "notificationUnread"] }),
    ]);
  }

  const activeBrands = includeBrands ? brandAccounts : [];
  const allUnreadKnown = !unread.isError && unread.data !== undefined && activeBrands.every(did => brandUnread[did] !== undefined);
  const unreadSubtitle = allUnreadKnown ? `${unread.data! + activeBrands.reduce((sum, did) => sum + brandUnread[did]!, 0)} Unread` : unread.isError ? "Unread Counts Unavailable" : unread.data === undefined ? "Social" : `${unread.data} Personal Unread · Brand Counts Unavailable`;
  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title="Notifications" subtitle={!moderation ? "Social" : unreadSubtitle}>
      <Button size="sm" variant="ghost" disabled={!moderation || markSeen.isPending || notifications.isPending || !!error} onClick={() => markSeen.mutate()}>{markSeen.isPending ? "Marking…" : brandAccounts.length ? "Mark Personal As Read" : "Mark All As Read"}</Button>
      <Button size="sm" variant="ghost" disabled={catalog.isFetching || notifications.isFetching} onClick={() => { void refresh(); }}>Refresh</Button>
    </FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain" key={session?.did}>
      <div className="mx-auto flex max-w-2xl flex-col gap-4 p-3 sm:p-4">
        {session ? <BrandNotificationSections ownerDid={session.did} accounts={brandAccounts} included={includeBrands} setIncluded={changeIncludeBrands} onUnread={reportBrandUnread} /> : null}
        {includeBrands && brandAccounts.length ? <h2 className="font-semibold">Personal Notifications</h2> : null}
        {markSeen.isError || unread.isError ? <section role="alert" className="flex flex-col items-start gap-2"><p className="text-sm text-destructive">{socialDiscoveryErrorMessage(markSeen.error ?? unread.error, "Notifications")}</p>{socialDiscoveryErrorMessage(markSeen.error ?? unread.error, "Notifications") === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" onClick={() => { void unread.refetch(); }}>Retry Unread Status</Button>}</section> : null}
        {error ? <section role="alert" className="flex flex-col items-start gap-3 py-4">
          <h2 className="text-lg font-semibold">Notifications Unavailable</h2><p className="text-sm text-muted-foreground">{error}</p>
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void refresh(); }}>Retry</Button>}
        </section> : !moderation || notifications.isPending ? <SocialTimelineSkeleton /> : <>
          {groups.map(group => {
            const notification = group.latest;
            const uri = notificationPostUri(notification);
            const item = notificationFeedItem(notification, posts);
            return <section key={group.key} aria-label={`Notification: ${notification.reason}`} className="flex flex-col gap-3 rounded-2xl border bg-card p-4">
              <SocialNotificationGroupHeader group={group} moderation={moderation} />
              {item ? <InteractiveSocialPost item={item} moderation={moderation} showReplyParentActions /> : uri ? <SocialPostLink uri={uri} moderation={moderation} /> : null}
            </section>;
          })}
          {!rows.length ? <p className="py-8 text-center text-sm text-muted-foreground">No notifications to show.</p> : null}
          {notifications.hasNextPage ? <Button variant="outline" disabled={notifications.isFetchingNextPage} onClick={() => { void notifications.fetchNextPage(); }}>{notifications.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
        </>}
      </div>
    </div>
  </div>;
}
