"use client";

import { Rows3 } from "lucide-react";

import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import {
  TOP_LEVEL_FEED_LABELS,
  type TopLevelFeed,
} from "@/lib/feedPreferences";

export function AllFeedSidebarButton({
  feed,
  isActive,
  onSelect,
}: {
  feed: TopLevelFeed;
  isActive: boolean;
  onSelect: (feed: TopLevelFeed) => void;
}) {
  const label = `All ${TOP_LEVEL_FEED_LABELS[feed]}`;

  return (
    <SidebarMenu className="mb-2 border-b border-sidebar-border pb-2">
      <SidebarMenuItem>
        <SidebarMenuButton
          type="button"
          isActive={isActive}
          aria-current={isActive ? "page" : undefined}
          onClick={() => onSelect(feed)}
        >
          <Rows3 />
          <span>{label}</span>
        </SidebarMenuButton>
      </SidebarMenuItem>
    </SidebarMenu>
  );
}
