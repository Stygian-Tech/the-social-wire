import { notificationIdentity, notificationPostUri, type SocialNotification } from "./blueskySocialDiscoveryClient";

export type SocialNotificationGroup = {
  key: string;
  notifications: SocialNotification[];
  latest: SocialNotification;
  authors: SocialNotification["author"][];
  isRead: boolean;
};

function notificationGroupKey(notification: SocialNotification): string {
  // Each of these events contains its own post, which must remain visible.
  if (["reply", "mention", "quote", "subscribed-post"].includes(notification.reason)) {
    return `${notification.reason}:${notification.uri}`;
  }
  if (["like", "repost", "like-via-repost", "repost-via-repost"].includes(notification.reason)) {
    const subject = notificationPostUri(notification);
    // Without a usable target, combining actions could hide unrelated posts.
    return subject ? `${notification.reason}|${subject}` : `${notification.reason}:${notification.uri}`;
  }
  return `${notification.reason}|${notification.reasonSubject ?? notification.reason}`;
}

/** Preserves API encounter order; overlapping pages never duplicate an event. */
export function groupSocialNotifications(notifications: readonly SocialNotification[]): SocialNotificationGroup[] {
  const seen = new Set<string>();
  const grouped = new Map<string, SocialNotification[]>();
  for (const notification of notifications) {
    const identity = notificationIdentity(notification);
    if (seen.has(identity)) continue;
    seen.add(identity);
    const key = notificationGroupKey(notification);
    const group = grouped.get(key);
    if (group) group.push(notification);
    else grouped.set(key, [notification]);
  }
  return [...grouped].map(([key, items]) => {
    const authors = new Map<string, SocialNotification["author"]>();
    for (const notification of items) {
      if (!authors.has(notification.author.did)) authors.set(notification.author.did, notification.author);
    }
    return {
      key,
      notifications: items,
      latest: items[0],
      authors: [...authors.values()],
      isRead: items.every(notification => notification.isRead),
    };
  });
}
