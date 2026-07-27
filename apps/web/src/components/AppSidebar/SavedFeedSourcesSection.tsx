"use client";

import { Avatar } from "@/components/shared/Avatar";
import {
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import type { SavedFeedSource } from "@/lib/savedFeedSources";

export function SavedFeedSourcesSection({
  sources,
  selectedSource,
  onSelectSource,
}: {
  sources: SavedFeedSource[];
  selectedSource: string | null;
  onSelectSource: (sourceKey: string) => void;
}) {
  if (sources.length === 0) return null;
  return (
    <>
      <SidebarGroupLabel>Publications</SidebarGroupLabel>
      <SidebarMenu aria-label="Saved Feed Publications">
        {sources.map((source) => (
          <SidebarMenuItem key={source.key}>
            <SidebarMenuButton
              type="button"
              isActive={selectedSource === source.key}
              onClick={() => onSelectSource(source.key)}
              className={source.count > 0 ? "relative pr-8" : undefined}
            >
              <Avatar
                src={source.faviconUrl}
                alt=""
                size={20}
                className="size-5 shrink-0"
              />
              <span>{source.name}</span>
              <SidebarMenuBadge>{source.count}</SidebarMenuBadge>
            </SidebarMenuButton>
          </SidebarMenuItem>
        ))}
      </SidebarMenu>
    </>
  );
}
