"use client";

import { Network, Newspaper, Rss, Users } from "lucide-react";

import {
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { ReaderNavigationFeed } from "@/lib/feedPreferences";
import type { PublicationTab } from "./appSidebarConstants";
import { SidebarSectionUnreadBadge } from "./SidebarSectionUnreadBadge";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import { WireBetaBadge } from "@/components/Wire/WireBetaBadge";

export function PublicationTabs({
  visibleFeeds,
  activeTab,
  onTabChange,
  subscribedUnread = 0,
  followingUnread = 0,
  showSubscribedUnreadCount = true,
  showFollowingUnreadCount = true,
  subscribedPublications = [],
  followingPublications = [],
  wireActive = false,
  onWireSelect,
  circleActive = false,
  onCircleSelect,
}: {
  visibleFeeds?: ReadonlySet<ReaderNavigationFeed>;
  activeTab: PublicationTab | null;
  onTabChange: (tab: PublicationTab) => void;
  subscribedUnread?: number;
  followingUnread?: number;
  showSubscribedUnreadCount?: boolean;
  showFollowingUnreadCount?: boolean;
  subscribedPublications?: DiscoveredPublication[];
  followingPublications?: DiscoveredPublication[];
  wireActive?: boolean;
  onWireSelect?: () => void;
  circleActive?: boolean;
  onCircleSelect?: () => void;
}) {
  if (
    visibleFeeds &&
    !["wire", "circle", "subscribed", "following"].some((feed) =>
      visibleFeeds.has(feed as ReaderNavigationFeed),
    )
  )
    return null;
  return (
    <SidebarGroup className="pb-1 pt-1">
      <SidebarGroupLabel>Feeds</SidebarGroupLabel>
      <SidebarMenu
        className="gap-0.5"
        role="tablist"
        aria-label="Publication Source"
      >
        {visibleFeeds?.has("wire") !== false ? (
          <SidebarMenuItem>
            <SidebarMenuButton
              type="button"
              role="tab"
              aria-label="The Wire, Beta"
              aria-selected={wireActive}
              isActive={wireActive}
              onClick={onWireSelect}
            >
              <Rss />
              <span>The Wire</span>
              <WireBetaBadge className="ml-auto" />
            </SidebarMenuButton>
          </SidebarMenuItem>
        ) : null}
        {visibleFeeds?.has("circle") !== false ? (
          <SidebarMenuItem>
            <SidebarMenuButton
              type="button"
              role="tab"
              aria-label="Your Circle, Beta"
              aria-selected={circleActive}
              isActive={circleActive}
              onClick={onCircleSelect}
            >
              <Network />
              <span>Your Circle</span>
              <WireBetaBadge className="ml-auto" />
            </SidebarMenuButton>
          </SidebarMenuItem>
        ) : null}
        {visibleFeeds?.has("subscribed") !== false ? (
          <SidebarMenuItem>
            <SidebarReadBulkMenuWrap
              publications={subscribedPublications}
              gatewayScopes={[{ kind: "subscribed" }]}
              markAllReadConfirmation="This marks every unread article in Subscribed as read."
              showMarkAllUnread={false}
            >
              <SidebarMenuButton
                type="button"
                role="tab"
                aria-selected={activeTab === "subscribed"}
                isActive={activeTab === "subscribed"}
                onClick={() => onTabChange("subscribed")}
              >
                <Newspaper />
                <span>Subscribed</span>
                {showSubscribedUnreadCount && subscribedUnread > 0 ? (
                  <SidebarSectionUnreadBadge count={subscribedUnread} />
                ) : null}
              </SidebarMenuButton>
            </SidebarReadBulkMenuWrap>
          </SidebarMenuItem>
        ) : null}
        {visibleFeeds?.has("following") !== false ? (
          <SidebarMenuItem>
            <SidebarReadBulkMenuWrap
              publications={followingPublications}
              gatewayScopes={[{ kind: "following" }]}
              markAllReadConfirmation="This marks every unread article in Following as read."
              showMarkAllUnread={false}
            >
              <SidebarMenuButton
                type="button"
                role="tab"
                aria-selected={activeTab === "following"}
                isActive={activeTab === "following"}
                onClick={() => onTabChange("following")}
              >
                <Users />
                <span>Following</span>
                {showFollowingUnreadCount && followingUnread > 0 ? (
                  <SidebarSectionUnreadBadge count={followingUnread} />
                ) : null}
              </SidebarMenuButton>
            </SidebarReadBulkMenuWrap>
          </SidebarMenuItem>
        ) : null}
      </SidebarMenu>
    </SidebarGroup>
  );
}
