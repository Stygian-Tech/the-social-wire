"use client";

import { moderateNotification, moderateProfile } from "@atproto/api";
import { useQueryClient } from "@tanstack/react-query";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialNotifications, useSocialNotificationUnread, useMarkSocialNotificationsSeen } from "@/hooks/useSocialDiscovery";
import { notificationIdentity, notificationPostUri, socialDiscoveryErrorMessage } from "@/lib/blueskySocialDiscoveryClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { InteractiveSocialPost } from "./InteractiveSocialPost";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialTimelineSkeleton } from "./SocialTimelineSkeleton";
import { moderateSocialPost } from "./socialModeration";
import { socialHttpsUrl, socialPostUrl, socialProfileUrl } from "./socialUrls";

const reasons: Record<string, string> = { like: "Liked Your Post", repost: "Reposted Your Post", follow: "Followed You", mention: "Mentioned You", reply: "Replied to Your Post", quote: "Quoted Your Post", "starterpack-joined": "Joined Your Starter Pack", verified: "Verified Your Account", unverified: "Removed Your Verification", "like-via-repost": "Liked a Post You Reposted", "repost-via-repost": "Reposted a Post You Reposted", "subscribed-post": "Posted an Update", "contact-match": "Joined Bluesky" };

export function SocialNotifications() {
  const { session } = useAuth();
  return <SocialNotificationsViewer key={session?.did ?? "signed-out"} />;
}

function SocialNotificationsViewer() {
  const { session } = useAuth();
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
    if (seen.has(key) || decision.filter || decision.blur || (post && moderateSocialPost(post, moderation).ui("contentList").filter)) return false;
    seen.add(key); return true;
  }) : [];
  async function refresh() {
    const settings = await catalog.refetch();
    if (!settings.isError && session) await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["blueskySocial", session.did, "notifications"] }),
      queryClient.invalidateQueries({ queryKey: ["blueskySocial", session.did, "notificationUnread"] }),
    ]);
  }

  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title="Notifications" subtitle={!moderation || unread.data === undefined ? "Social" : `${unread.data} Unread`}>
      <Button size="sm" variant="ghost" disabled={!moderation || markSeen.isPending || notifications.isPending || !!error} onClick={() => markSeen.mutate()}>{markSeen.isPending ? "Marking…" : "Mark All As Read"}</Button>
      <Button size="sm" variant="ghost" disabled={catalog.isFetching || notifications.isFetching} onClick={() => { void refresh(); }}>Refresh</Button>
    </FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain" key={session?.did}>
      <div className="mx-auto flex max-w-2xl flex-col gap-4 p-3 sm:p-4">
        {markSeen.isError || unread.isError ? <section role="alert" className="flex flex-col items-start gap-2"><p className="text-sm text-destructive">{socialDiscoveryErrorMessage(markSeen.error ?? unread.error, "Notifications")}</p>{socialDiscoveryErrorMessage(markSeen.error ?? unread.error, "Notifications") === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" onClick={() => { void unread.refetch(); }}>Retry Unread Status</Button>}</section> : null}
        {error ? <section role="alert" className="flex flex-col items-start gap-3 py-4">
          <h2 className="text-lg font-semibold">Notifications Unavailable</h2><p className="text-sm text-muted-foreground">{error}</p>
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void refresh(); }}>Retry</Button>}
        </section> : !moderation || notifications.isPending ? <SocialTimelineSkeleton /> : <>
          {rows.map(notification => {
            const uri = notificationPostUri(notification);
            const post = uri ? posts.get(uri) : undefined;
            const postHref = uri ? socialPostUrl(uri) : undefined;
            const name = notification.author.displayName || notification.author.handle;
            const avatarHidden = moderateProfile(notification.author, moderation).ui("avatar").blur;
            return <section key={notificationIdentity(notification)} aria-label={`${name}: ${reasons[notification.reason] ?? "Sent a Notification"}`} className="flex flex-col gap-3 rounded-2xl border bg-card p-4">
              <div className="flex items-start gap-3">
                <Avatar src={avatarHidden ? undefined : socialHttpsUrl(notification.author.avatar)} alt="" size={36} />
                <div className="min-w-0 flex-1">
                  <a href={socialProfileUrl(notification.author.did)} target="_blank" rel="noopener noreferrer" className="break-words font-semibold hover:underline">{name}</a>
                  <p className="text-sm">{reasons[notification.reason] ?? "Sent a Notification"}</p>
                  <time dateTime={notification.indexedAt} className="text-xs text-muted-foreground">{new Date(notification.indexedAt).toLocaleString()}</time>
                </div>
                {!notification.isRead ? <span className="text-xs font-semibold text-primary">Unread</span> : null}
              </div>
              {post ? <InteractiveSocialPost item={{ post }} moderation={moderation} /> : postHref ? <a href={postHref} target="_blank" rel="noopener noreferrer" className="text-sm text-primary hover:underline">View Post on Bluesky</a> : null}
            </section>;
          })}
          {!rows.length ? <p className="py-8 text-center text-sm text-muted-foreground">No notifications to show.</p> : null}
          {notifications.hasNextPage ? <Button variant="outline" disabled={notifications.isFetchingNextPage} onClick={() => { void notifications.fetchNextPage(); }}>{notifications.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
        </>}
      </div>
    </div>
  </div>;
}
