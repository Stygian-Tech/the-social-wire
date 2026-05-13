"use client";

import { SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";
import { Avatar } from "@/components/shared/Avatar";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

interface PublicationItemProps {
  publication: DiscoveredPublication;
  isSelected: boolean;
  onSelect: (publicationId: string) => void;
}

export function PublicationItem({
  publication,
  isSelected,
  onSelect,
}: PublicationItemProps) {
  return (
    <SidebarMenuItem>
      <SidebarMenuButton
        isActive={isSelected}
        onClick={() => onSelect(publication.publicationId)}
        className="gap-2"
      >
        <Avatar
          src={publication.avatarUrl}
          alt={publication.title}
          size={20}
          className="shrink-0"
        />
        <span className="truncate text-sm">{publication.title}</span>
      </SidebarMenuButton>
    </SidebarMenuItem>
  );
}
