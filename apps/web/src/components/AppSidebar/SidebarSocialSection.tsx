"use client";

import { Bell, Bookmark, Compass, House, List, MessagesSquare, Rss } from "lucide-react";
import { SidebarGroup, SidebarGroupLabel, SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";

export const SOCIAL_DESTINATIONS = [
  { name: "Home", section: "home", icon: House, href: "/social" },
  { name: "Explore", section: "explore", icon: Compass, href: "/social/explore" },
  { name: "Notifications", section: "notifications", icon: Bell, href: "/social/notifications" },
  { name: "Messages", section: "messages", icon: MessagesSquare, href: "/social/messages" },
  { name: "Bookmarks", section: "bookmarks", icon: Bookmark, href: "/social/bookmarks" },
  { name: "Lists", section: "lists", icon: List, href: "/social/lists" },
  { name: "Feeds", section: "feeds", icon: Rss, href: "/social/feeds" },
] as const;

export function SidebarSocialSection({ active, activeSection = "home", onHome, onNavigate }: {
  active: boolean;
  activeSection?: string;
  onHome: () => void;
  onNavigate?: (href: string) => void;
}) {
  return <SidebarGroup className="pb-1 pt-1">
    <SidebarGroupLabel>Social</SidebarGroupLabel>
    <SidebarMenu className="gap-0.5" aria-label="Social Navigation">
      {SOCIAL_DESTINATIONS.map(({ name, section, icon: Icon, href }) => {
        const selected = active && activeSection === section;
        return <SidebarMenuItem key={section}>
          <SidebarMenuButton type="button" aria-label={`Social ${name}`} aria-current={selected ? "page" : undefined} isActive={selected} tooltip={name} onClick={() => section === "home" ? onHome() : onNavigate?.(href)}>
            <Icon aria-hidden="true" /><span className="truncate">{name}</span>
          </SidebarMenuButton>
        </SidebarMenuItem>;
      })}
    </SidebarMenu>
  </SidebarGroup>;
}
