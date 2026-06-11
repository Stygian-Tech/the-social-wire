"use client";

import { memo } from "react";
import { ChevronRight } from "lucide-react";

import { FolderBranch } from "./FolderBranch";
import { NewFolderDialog } from "./NewFolderDialog";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import { SidebarSubMenuSkeletonRows } from "./SidebarSubMenuSkeletonRows";
import { UnreadSidebarBadge } from "./UnreadSidebarBadge";
import { SIDEBAR_SEC_FOLDERS } from "./appSidebarConstants";
import { folderExpandKey } from "@/lib/sidebarExpandedKeysStorage";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type {
  FolderRecord,
  PublicationPrefsRecord,
  RepoRecord,
} from "@/lib/pdsClient";
import { rkeyFromURI } from "@/lib/pdsClient";
import {
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
} from "@/components/ui/sidebar";
import { cn } from "@/lib/utils";

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
  onToggleSection: () => void;
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
  onToggleSection,
  onToggleFolder,
  prefsMap,
  publicationUnreadCounts,
  allFolderedPublicationsForBulk,
}: SidebarFoldersSectionProps) {
  const sectionExpanded = effectiveExpandedKeys.has(SIDEBAR_SEC_FOLDERS);

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
        <SidebarMenuButton
          type="button"
          onClick={onToggleSection}
          aria-expanded={sectionExpanded}
          className={cn(
            "gap-2",
            foldersSectionUnread > 0 && "relative pr-8"
          )}
        >
          <ChevronRight
            className={cn(
              "size-4 shrink-0 transition-transform",
              sectionExpanded && "rotate-90"
            )}
            aria-hidden
          />
          <span className="min-w-0 flex-1 truncate text-left text-xs font-medium">
            Folders
          </span>
          <UnreadSidebarBadge count={foldersSectionUnread} />
        </SidebarMenuButton>
      </SidebarReadBulkMenuWrap>
      {sectionExpanded ? (
        <SidebarMenuSub aria-label="Folders" className="mt-1.5">
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
      ) : null}
    </SidebarMenuItem>
  );
}

export const SidebarFoldersSection = memo(SidebarFoldersSectionInner);
