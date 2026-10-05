"use client";

import { Headphones, ChartNoAxesCombined, Trophy } from "lucide-react";

import {
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import { WireBetaBadge } from "@/components/Wire/WireBetaBadge";
import type { ReaderNavigationFeed } from "@/lib/feedPreferences";

export function SidebarTopicsSection({
  visibleFeeds,
  podcastsEnabled = false,
  podcastsActive = false,
  onPodcastsSelect,
  sportsEnabled = false,
  sportsActive = false,
  onSportsSelect,
  financeActive = false,
  onFinanceSelect,
}: {
  podcastsEnabled?: boolean;
  podcastsActive?: boolean;
  onPodcastsSelect?: () => void;
  visibleFeeds?: ReadonlySet<ReaderNavigationFeed>;
  sportsEnabled?: boolean;
  sportsActive?: boolean;
  onSportsSelect?: () => void;
  financeActive?: boolean;
  onFinanceSelect?: () => void;
}) {
  if (!podcastsEnabled && visibleFeeds?.has("finance") === false && (!sportsEnabled || visibleFeeds?.has("sports") === false)) return null;

  return (
    <SidebarGroup className="pb-1 pt-1">
      <SidebarGroupLabel>Topics</SidebarGroupLabel>
      <SidebarMenu className="gap-0.5" role="tablist" aria-label="Topics">
        {podcastsEnabled ? <SidebarMenuItem><SidebarMenuButton type="button" role="tab" aria-selected={podcastsActive} isActive={podcastsActive} onClick={onPodcastsSelect}><Headphones /><span>Podcasts</span></SidebarMenuButton></SidebarMenuItem> : null}
        {visibleFeeds?.has("finance") !== false ? <SidebarMenuItem>
          <SidebarMenuButton
            type="button"
            role="tab"
            aria-label="Finance, Beta"
            aria-selected={financeActive}
            isActive={financeActive}
            onClick={onFinanceSelect}
          >
            <ChartNoAxesCombined />
            <span>Finance</span>
            <WireBetaBadge className="ml-auto" />
          </SidebarMenuButton>
        </SidebarMenuItem> : null}
        {sportsEnabled && visibleFeeds?.has("sports") !== false ? <SidebarMenuItem><SidebarMenuButton type="button" role="tab" aria-label="Sports, Beta" aria-selected={sportsActive} isActive={sportsActive} onClick={onSportsSelect}><Trophy /><span>Sports</span><WireBetaBadge className="ml-auto" /></SidebarMenuButton></SidebarMenuItem> : null}
      </SidebarMenu>
    </SidebarGroup>
  );
}
