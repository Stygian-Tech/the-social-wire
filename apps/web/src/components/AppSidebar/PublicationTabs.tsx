"use client";

import { Rss, Users } from "lucide-react";

import {
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import type { PublicationTab } from "./appSidebarConstants";
import { SidebarMenuBadge } from "@/components/ui/sidebar";

export function PublicationTabs({
  activeTab,
  onTabChange,
  subscribedUnread = 0,
  followingUnread = 0,
  showUnreadCounts = true,
  visibleTabs = ["subscribed", "following"],
}: {
  activeTab: PublicationTab | null;
  onTabChange: (tab: PublicationTab) => void;
  subscribedUnread?: number;
  followingUnread?: number;
  showUnreadCounts?: boolean;
  visibleTabs?: PublicationTab[];
}) {
  return (
    <SidebarGroup className="pb-1 pt-1">
      <SidebarGroupLabel>Feeds</SidebarGroupLabel>
      <SidebarMenu className="gap-0.5" role="tablist" aria-label="Publication Source">
        {visibleTabs.includes("subscribed") ? <SidebarMenuItem>
          <SidebarMenuButton
            type="button"
            role="tab"
            aria-selected={activeTab === "subscribed"}
            isActive={activeTab === "subscribed"}
            onClick={() => onTabChange("subscribed")}
          >
            <Rss />
            <span>Subscribed</span>
            {showUnreadCounts && subscribedUnread > 0 ? (
              <SidebarMenuBadge>{subscribedUnread}</SidebarMenuBadge>
            ) : null}
          </SidebarMenuButton>
        </SidebarMenuItem> : null}
        {visibleTabs.includes("following") ? <SidebarMenuItem>
          <SidebarMenuButton
            type="button"
            role="tab"
            aria-selected={activeTab === "following"}
            isActive={activeTab === "following"}
            onClick={() => onTabChange("following")}
          >
            <Users />
            <span>Following</span>
            {showUnreadCounts && followingUnread > 0 ? (
              <SidebarMenuBadge>{followingUnread}</SidebarMenuBadge>
            ) : null}
          </SidebarMenuButton>
        </SidebarMenuItem> : null}
      </SidebarMenu>
    </SidebarGroup>
  );
}
