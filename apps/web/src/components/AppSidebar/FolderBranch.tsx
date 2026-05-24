"use client";

import { ChevronRight, Folder } from "lucide-react";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import {
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  SidebarMenuSubItem,
} from "@/components/ui/sidebar";
import { SidebarSubMenuSkeletonRows } from "./SidebarSubMenuSkeletonRows";
import { cn } from "@/lib/utils";
import { sumUnreadForPublications } from "@/lib/unreadCounts";
import {
  PublicationSubItem,
  type PublicationSidebarTab,
} from "./PublicationSubItem";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type {
  RepoRecord,
  FolderRecord,
  PublicationPrefsRecord,
} from "@/lib/pdsClient";
import { useDeleteFolder } from "@/hooks/useFolders";
import { rkeyFromURI } from "@/lib/pdsClient";

export type FolderBranchDisplay = Pick<
  RepoRecord<FolderRecord>["value"],
  "name" | "icon" | "iconImage"
>;

interface FolderBranchProps {
  expandKey: string;
  folderUri: string;
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
  sidebarTab: PublicationSidebarTab;
  publicationUnreadCounts: Map<string, number>;
  /** Shown after the folder name (e.g. All → unfoldered) */
  nameSuffix?: string;
  publicationsLoading?: boolean;
}

export function FolderBranch({
  expandKey,
  folderUri,
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
  sidebarTab,
  publicationUnreadCounts,
  nameSuffix,
  publicationsLoading = false,
}: FolderBranchProps) {
  const deleteFolder = useDeleteFolder();
  const folderRkey = rkeyFromURI(folderUri);
  const subId = `sidebar-folder-sub-${expandKey.replace(/[^a-zA-Z0-9_-]/g, "_")}`;
  const folderUnread = sumUnreadForPublications(
    publications,
    publicationUnreadCounts
  );

  return (
    <SidebarMenuItem>
      <SidebarReadBulkMenuWrap
        publications={publications}
        gatewayScopes={
          folderRkey ? [{ kind: "folder", folderRkey }] : undefined
        }
        markAllReadConfirmation={
          <>
            This marks every cached article in the folder &quot;{folder.name}&quot; as read.
            Entries that have not been loaded yet stay unchanged until you open them.
          </>
        }
        destructiveAction={{
          label: "Delete Folder",
          confirmationTitle: "Delete Folder?",
          confirmationDescription: (
            <>
              Delete &quot;{folder.name}&quot; and move its publications back to Publications.
              This cannot be undone.
            </>
          ),
          pending: deleteFolder.isPending,
          onConfirm: () => {
            deleteFolder.mutate(folderUri);
          },
        }}
      >
        <SidebarMenuButton
          type="button"
          isActive={isActive}
          onClick={onToggleExpanded}
          aria-expanded={expanded}
          aria-controls={subId}
          className={cn(
            "gap-2",
            folderUnread > 0 && "relative pr-8"
          )}
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
          {folderUnread > 0 ? (
            <SidebarMenuBadge aria-label={`${folderUnread} unread`}>
              {folderUnread}
            </SidebarMenuBadge>
          ) : null}
        </SidebarMenuButton>
      </SidebarReadBulkMenuWrap>
      {expanded ? (
        <SidebarMenuSub id={subId} aria-label={folder.name} className="mt-1.5">
          {publicationsLoading && publications.length === 0 ? (
            <SidebarSubMenuSkeletonRows count={2} />
          ) : publications.length === 0 ? (
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
                unreadCount={publicationUnreadCounts.get(pub.publicationId) ?? 0}
                isSelected={selectedPubId === pub.publicationId}
                onSelect={onSelectPub}
                folders={folders}
                prefsMap={prefsMap}
                sidebarTab={sidebarTab}
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
