"use client";

import { memo } from "react";

import { AddPublicationDialog } from "./AddPublicationDialog";
import { CollapsibleSidebarSubSection } from "./CollapsibleSidebarSubSection";
import { PublicationMenuSubEntries } from "./PublicationMenuSubEntries";
import type { PublicationSidebarTab } from "./PublicationSubItem";
import { SIDEBAR_SEC_PUBLICATIONS } from "./appSidebarConstants";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type {
  FolderRecord,
  PublicationPrefsRecord,
  RepoRecord,
} from "@/lib/pdsClient";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";
import { SidebarMenuSubItem } from "@/components/ui/sidebar";

export type SidebarPublicationsSectionProps = {
  publications: DiscoveredPublication[];
  publicationUnreadCounts: Map<string, number>;
  publicationsSectionUnread: number;
  effectiveExpandedKeys: Set<string>;
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
  onToggleSection: () => void;
  folders: RepoRecord<FolderRecord>[];
  prefsMap: Map<string, RepoRecord<PublicationPrefsRecord>>;
  sidebarTab: PublicationSidebarTab;
  listLoading: boolean;
  readBulkMarkAllReadConfirmation: React.ReactNode;
  gatewayMarkAllReadScopes?: GatewayMarkAllReadScope[];
};

function SidebarPublicationsSectionInner({
  publications,
  publicationUnreadCounts,
  publicationsSectionUnread,
  effectiveExpandedKeys,
  selectedPubId,
  onSelectPub,
  onToggleSection,
  folders,
  prefsMap,
  sidebarTab,
  listLoading,
  readBulkMarkAllReadConfirmation,
  gatewayMarkAllReadScopes,
}: SidebarPublicationsSectionProps) {
  const subAriaLabel =
    sidebarTab === "subscribed"
      ? "Subscribed Publications"
      : "Publications From Followed Accounts";

  return (
    <CollapsibleSidebarSubSection
      title="Publications"
      unreadCount={publicationsSectionUnread}
      expanded={effectiveExpandedKeys.has(SIDEBAR_SEC_PUBLICATIONS)}
      onToggle={onToggleSection}
      subAriaLabel={subAriaLabel}
      readBulkPublications={publications}
      readBulkMarkAllReadConfirmation={readBulkMarkAllReadConfirmation}
      gatewayMarkAllReadScopes={gatewayMarkAllReadScopes}
    >
      <PublicationMenuSubEntries
        publications={publications}
        publicationUnreadCounts={publicationUnreadCounts}
        selectedPubId={selectedPubId}
        onSelectPub={onSelectPub}
        folders={folders}
        prefsMap={prefsMap}
        sidebarTab={sidebarTab}
        listLoading={listLoading}
      />
      {!listLoading ? (
        <SidebarMenuSubItem className="p-0">
          <AddPublicationDialog />
        </SidebarMenuSubItem>
      ) : null}
    </CollapsibleSidebarSubSection>
  );
}

export const SidebarPublicationsSection = memo(SidebarPublicationsSectionInner);
