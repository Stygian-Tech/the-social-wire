"use client";

import { memo } from "react";

import { FolderBranch } from "./FolderBranch";
import { NewFolderDialog } from "./NewFolderDialog";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import { SidebarSubMenuSkeletonRows } from "./SidebarSubMenuSkeletonRows";
import { SidebarSectionUnreadBadge } from "./SidebarSectionUnreadBadge";
import { folderExpandKey } from "@/lib/sidebarExpandedKeysStorage";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type {
  FolderRecord,
  PublicationPrefsRecord,
  RepoRecord,
} from "@/lib/pdsClient";
import { rkeyFromURI } from "@/lib/pdsClient";
import { SidebarMenuItem, SidebarMenuSub } from "@/components/ui/sidebar";

export type SidebarFoldersSectionProps = {
  folders: RepoRecord<FolderRecord>[];
  folderMap: Map<string, DiscoveredPublication[]>;
  foldersListLoading: boolean;
  folderPublicationsLoading: boolean;
  foldersSectionUnread: number;
  effectiveExpandedKeys: Set<string>;
  selectedFolderUri: string | null;
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
  onToggleFolder: (expandKey: string) => void;
  prefsMap: Map<string, RepoRecord<PublicationPrefsRecord>>;
  publicationUnreadCounts: Map<string, number>;
  allFolderedPublicationsForBulk: DiscoveredPublication[];
};

function SidebarFoldersSectionInner({
  folders,
  folderMap,
  foldersListLoading,
  folderPublicationsLoading,
  foldersSectionUnread,
  effectiveExpandedKeys,
  selectedFolderUri,
  selectedPubId,
  onSelectPub,
  onToggleFolder,
  prefsMap,
  publicationUnreadCounts,
  allFolderedPublicationsForBulk,
}: SidebarFoldersSectionProps) {
  return (
    <SidebarMenuItem>
      <SidebarReadBulkMenuWrap
        publications={allFolderedPublicationsForBulk}
        markAllReadConfirmation={
          <>
            This marks every cached article across all folders as read. Entries
            that have not been loaded yet stay unchanged until you open them.
          </>
        }
      >
        <div className="flex h-6 w-full min-w-0 items-center gap-2 pl-2 pr-1 text-xs font-medium text-sidebar-foreground/70">
          <span className="min-w-0 flex-1 truncate">Folders</span>
          <SidebarSectionUnreadBadge count={foldersSectionUnread} />
        </div>
      </SidebarReadBulkMenuWrap>
      <SidebarMenuSub aria-label="Folders">
        {foldersListLoading ? (
          <SidebarSubMenuSkeletonRows count={2} />
        ) : (
          folders.map((f) => {
            const rkey = rkeyFromURI(f.uri);
            const expandKey = folderExpandKey(rkey);
            return (
              <FolderBranch
                key={f.uri}
                expandKey={expandKey}
                folderUri={f.uri}
                folder={f.value}
                isActive={selectedFolderUri === f.uri}
                expanded={effectiveExpandedKeys.has(expandKey)}
                onToggleExpanded={() => onToggleFolder(expandKey)}
                publications={folderMap.get(rkey) ?? []}
                emptyLabel="No publications in this folder."
                selectedPubId={selectedPubId}
                onSelectPub={onSelectPub}
                folders={folders}
                prefsMap={prefsMap}
                sidebarTab="subscribed"
                publicationUnreadCounts={publicationUnreadCounts}
                publicationsLoading={folderPublicationsLoading}
              />
            );
          })
        )}
        <SidebarMenuItem>
          <NewFolderDialog />
        </SidebarMenuItem>
      </SidebarMenuSub>
    </SidebarMenuItem>
  );
}

export const SidebarFoldersSection = memo(SidebarFoldersSectionInner);
