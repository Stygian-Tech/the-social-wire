"use client";

import { Folder } from "lucide-react";
import { SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";
import type { RepoRecord, FolderRecord } from "@/lib/pdsClient";

interface FolderItemProps {
  folder: RepoRecord<FolderRecord>;
  isSelected: boolean;
  onSelect: (uri: string) => void;
}

export function FolderItem({ folder, isSelected, onSelect }: FolderItemProps) {
  const { name, icon, iconImage } = folder.value;

  return (
    <SidebarMenuItem>
      <SidebarMenuButton
        isActive={isSelected}
        onClick={() => onSelect(folder.uri)}
        className="gap-2"
      >
        <FolderIcon icon={icon} iconImage={iconImage} name={name} />
        <span className="truncate">{name}</span>
      </SidebarMenuButton>
    </SidebarMenuItem>
  );
}

function FolderIcon({
  icon,
  iconImage,
  name,
}: {
  icon?: string;
  iconImage?: string;
  name: string;
}) {
  if (iconImage) {
    // eslint-disable-next-line @next/next/no-img-element
    return (
      <img
        src={iconImage}
        alt={name}
        className="h-4 w-4 rounded object-cover"
      />
    );
  }
  if (icon) {
    return (
      <span className="text-sm leading-none" aria-hidden>
        {icon}
      </span>
    );
  }
  return <Folder className="h-4 w-4 shrink-0" aria-hidden />;
}
