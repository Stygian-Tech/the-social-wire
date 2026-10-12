"use client";

import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { useSocialNotificationUnread } from "@/hooks/useSocialDiscovery";
import { getBlueskyMessageUnread } from "@/lib/blueskyChatClient";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useSocialUnreadCounts() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const notifications = useSocialNotificationUnread(true, 30_000);
  const available = !!getAtprotoNetwork().chatServiceDid;
  const messages = useQuery({
    // Shares the existing chat mutation invalidation prefix and account boundary.
    queryKey: ["blueskySocial", session?.did ?? "", "messages", oauthSessionReloadSeq, "unread"],
    enabled: available && !!session,
    queryFn: ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did) throw new Error("Your account changed. Please reload Messages.");
      return getBlueskyMessageUnread({ session: oauth, viewerDid: session!.did, signal });
    },
    staleTime: 15_000,
    refetchInterval: 30_000,
    retry: false,
  });
  return {
    notificationCount: notifications.isError ? 0 : notifications.data ?? 0,
    messageCount: !available || messages.isError ? 0 : messages.data ?? 0,
  };
}
