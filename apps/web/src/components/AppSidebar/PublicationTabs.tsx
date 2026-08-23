"use client";

import { Newspaper, Rss, Users } from "lucide-react";

import {
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { PublicationTab } from "./appSidebarConstants";
import { SidebarMenuBadge } from "@/components/ui/sidebar";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import { WireAlphaBadge } from "@/components/Wire/WireAlphaBadge";

export function PublicationTabs({
  activeTab,
  onTabChange,
  subscribedUnread = 0,
  followingUnread = 0,
  showSubscribedUnreadCount = true,
  showFollowingUnreadCount = true,
  visibleTabs = ["subscribed", "following"],
  subscribedPublications = [],
  followingPublications = [],
  wireEnabled = false,
  wireActive = false,
  onWireSelect,
}: {
  activeTab: PublicationTab | null;
  onTabChange: (tab: PublicationTab) => void;
  subscribedUnread?: number;
  followingUnread?: number;
  showSubscribedUnreadCount?: boolean;
  showFollowingUnreadCount?: boolean;
  visibleTabs?: PublicationTab[];
  subscribedPublications?: DiscoveredPublication[];
  followingPublications?: DiscoveredPublication[];
  wireEnabled?: boolean;
  wireActive?: boolean;
  onWireSelect?: () => void;
}) {
  return (
    <SidebarGroup className="pb-1 pt-1">
      <SidebarGroupLabel>Feeds</SidebarGroupLabel>
      <SidebarMenu className="gap-0.5" role="tablist" aria-label="Publication Source">
        {wireEnabled ? (
          <SidebarMenuItem>
            <SidebarMenuButton
              type="button"
              role="tab"
              aria-label="The Wire, Alpha"
              aria-selected={wireActive}
              isActive={wireActive}
              onClick={onWireSelect}
            >
              <Rss />
              <span>The Wire</span>
              <WireAlphaBadge />
            </SidebarMenuButton>
          </SidebarMenuItem>
        ) : null}
        {visibleTabs.includes("subscribed") ? (
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
                  <SidebarMenuBadge>{subscribedUnread}</SidebarMenuBadge>
                ) : null}
              </SidebarMenuButton>
            </SidebarReadBulkMenuWrap>
          </SidebarMenuItem>
        ) : null}
        {visibleTabs.includes("following") ? (
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
                  <SidebarMenuBadge>{followingUnread}</SidebarMenuBadge>
                ) : null}
              </SidebarMenuButton>
            </SidebarReadBulkMenuWrap>
          </SidebarMenuItem>
        ) : null}
      </SidebarMenu>
    </SidebarGroup>
  );
}
