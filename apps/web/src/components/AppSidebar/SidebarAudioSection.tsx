"use client";

import { Headphones } from "lucide-react";
import { WireBetaBadge } from "@/components/Wire/WireBetaBadge";
import { SidebarGroup, SidebarGroupLabel, SidebarMenu, SidebarMenuItem, SidebarMenuButton } from "@/components/ui/sidebar";

export function SidebarAudioSection({ enabled, active, onSelect }: { enabled: boolean; active: boolean; onSelect: () => void }) {
  if (!enabled) return null;
  return <SidebarGroup className="pb-1 pt-1">
    <SidebarGroupLabel>Audio</SidebarGroupLabel>
    <SidebarMenu role="tablist" aria-label="Audio">
      <SidebarMenuItem><SidebarMenuButton type="button" role="tab" aria-label="Podcasts, Beta" aria-selected={active} isActive={active} onClick={onSelect}>
        <Headphones /><span>Podcasts</span><WireBetaBadge className="ml-auto" />
      </SidebarMenuButton></SidebarMenuItem>
    </SidebarMenu>
  </SidebarGroup>;
}
