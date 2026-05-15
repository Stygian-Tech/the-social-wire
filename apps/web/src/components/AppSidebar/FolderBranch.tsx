"use client";

import { ChevronRight, Folder } from "lucide-react";
import {
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  SidebarMenuSubItem,
} from "@/components/ui/sidebar";
import { cn } from "@/lib/utils";
import { PublicationSubItem } from "./PublicationSubItem";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type {
  RepoRecord,
  FolderRecord,
  PublicationPrefsRecord,
} from "@/lib/pdsClient";

export type FolderBranchDisplay = Pick<
  RepoRecord<FolderRecord>["value"],
  "name" | "icon" | "iconImage"
>;

interface FolderBranchProps {
  expandKey: string;
  folder: FolderBranchDisplay;
  isActive: boolean;
  expanded: boolean;
  onToggleExpanded: () => void;
  publications: DiscoveredPublication[];
  emptyLabel: string;
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
  folders: RepoRecord<FolderRecord>[];
  prefsMap: Map<string, RepoRecord<PublicationPrefsRecord>>;
  /** Shown after the folder name (e.g. All → unfoldered) */
  nameSuffix?: string;
}

export function FolderBranch({
  expandKey,
  folder,
  isActive,
  expanded,
  onToggleExpanded,
  publications,
  emptyLabel,
  selectedPubId,
  onSelectPub,
  folders,
  prefsMap,
  nameSuffix,
}: FolderBranchProps) {
  const subId = `sidebar-folder-sub-${expandKey.replace(/[^a-zA-Z0-9_-]/g, "_")}`;

  return (
    <SidebarMenuItem>
      <SidebarMenuButton
        type="button"
        isActive={isActive}
        onClick={onToggleExpanded}
        aria-expanded={expanded}
        aria-controls={subId}
        className="gap-2"
      >
        <ChevronRight
          className={cn(
            "size-4 shrink-0 transition-transform",
            expanded && "rotate-90"
          )}
          aria-hidden
        />
        <FolderGlyph
          icon={folder.icon}
          iconImage={folder.iconImage}
          name={folder.name}
        />
        <span className="min-w-0 flex-1 truncate text-left">{folder.name}</span>
        {nameSuffix ? (
          <span className="text-muted-foreground shrink-0 text-[10px] leading-none">
            {nameSuffix}
          </span>
        ) : null}
      </SidebarMenuButton>
      {expanded ? (
        <SidebarMenuSub id={subId} aria-label={folder.name}>
          {publications.length === 0 ? (
            <SidebarMenuSubItem>
              <span className="block min-w-0 break-words px-2 py-0.5 text-xs text-muted-foreground">
                {emptyLabel}
              </span>
            </SidebarMenuSubItem>
          ) : (
            publications.map((pub) => (
              <PublicationSubItem
                key={pub.publicationId}
                publication={pub}
                isSelected={selectedPubId === pub.publicationId}
                onSelect={onSelectPub}
                folders={folders}
                prefsMap={prefsMap}
              />
            ))
          )}
        </SidebarMenuSub>
      ) : null}
    </SidebarMenuItem>
  );
}

function FolderGlyph({
  icon,
  iconImage,
  name,
}: {
  icon?: string;
  iconImage?: string;
  name: string;
}) {
  if (iconImage) {
    return (
      <>
        {/* eslint-disable-next-line @next/next/no-img-element -- arbitrary folder icon URLs */}
        <img
          src={iconImage}
          alt={name}
          className="h-4 w-4 rounded object-cover"
        />
      </>
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
