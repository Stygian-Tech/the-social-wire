"use client";

import { useState } from "react";
import { ChevronRight } from "lucide-react";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import {
  SidebarMenuBadge,
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
import { EditFolderDialog } from "./EditFolderDialog";
import { FolderIconGlyph } from "./FolderIcon";

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
  onSelectFolder: () => void;
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
  onSelectFolder,
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
  const [editOpen, setEditOpen] = useState(false);
  const folderRkey = rkeyFromURI(folderUri);
  const subId = `sidebar-folder-sub-${expandKey.replace(/[^a-zA-Z0-9_-]/g, "_")}`;
  const folderUnread = sumUnreadForPublications(
    publications,
    publicationUnreadCounts
  );

  return (
    <>
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
          menuActions={[
            {
              label: "Edit Folder",
              onSelect: () => setEditOpen(true),
            },
          ]}
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
          <div
            className={cn(
              "flex h-8 w-full min-w-0 items-center rounded-md",
              isActive && "bg-sidebar-accent text-sidebar-accent-foreground",
              folderUnread > 0 && "relative pr-8",
            )}
          >
            <button
              type="button"
              onClick={onToggleExpanded}
              className="flex size-8 shrink-0 items-center justify-center rounded-md hover:bg-sidebar-accent"
            aria-expanded={expanded}
            aria-controls={subId}
              aria-label={`${expanded ? "Collapse" : "Expand"} ${folder.name}`}
          >
            <ChevronRight
              className={cn(
                "size-4 shrink-0 transition-transform",
                expanded && "rotate-90"
              )}
              aria-hidden
            />
            </button>
            <button
              type="button"
              onClick={onSelectFolder}
              className="flex min-w-0 flex-1 items-center gap-2 text-left"
            >
            <FolderIconGlyph
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
            </button>
          </div>
        </SidebarReadBulkMenuWrap>
        {expanded ? (
          <SidebarMenuSub id={subId} aria-label={folder.name} className="mt-0.5 pl-5">
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
      <EditFolderDialog
        open={editOpen}
        onOpenChange={setEditOpen}
        folderUri={folderUri}
        folder={folder}
      />
    </>
  );
}
