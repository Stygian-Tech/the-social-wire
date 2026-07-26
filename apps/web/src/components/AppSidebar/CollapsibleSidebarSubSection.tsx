"use client";

import { useId, type ReactNode } from "react";
import { SidebarMenuItem, SidebarMenuSub } from "@/components/ui/sidebar";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import { SidebarSectionUnreadBadge } from "./SidebarSectionUnreadBadge";

export function CollapsibleSidebarSubSection({
  title,
  unreadCount = 0,
  subAriaLabel,
  readBulkPublications,
  readBulkMarkAllReadConfirmation,
  gatewayMarkAllReadScopes,
  children,
}: {
  title: string;
  unreadCount?: number;
  subAriaLabel: string;
  readBulkPublications?: DiscoveredPublication[];
  /** Required when `readBulkPublications` is provided */
  readBulkMarkAllReadConfirmation?: ReactNode;
  gatewayMarkAllReadScopes?: GatewayMarkAllReadScope[];
  children: ReactNode;
}) {
  const subId = `sidebar-collapsible-sub-${useId().replace(/:/g, "")}`;

  const sectionHeader = (
    <div
      className="flex h-6 w-full min-w-0 items-center gap-2 pl-2 pr-1 text-xs font-medium text-sidebar-foreground/70"
      aria-controls={subId}
    >
      <span className="min-w-0 flex-1 truncate">{title}</span>
      <SidebarSectionUnreadBadge count={unreadCount} />
    </div>
  );

  return (
    <SidebarMenuItem>
      {readBulkPublications !== undefined &&
      readBulkMarkAllReadConfirmation !== undefined ? (
        <SidebarReadBulkMenuWrap
          publications={readBulkPublications}
          markAllReadConfirmation={readBulkMarkAllReadConfirmation}
          gatewayScopes={gatewayMarkAllReadScopes}
        >
          {sectionHeader}
        </SidebarReadBulkMenuWrap>
      ) : (
        sectionHeader
      )}
      <SidebarMenuSub id={subId} aria-label={subAriaLabel}>
        {children}
      </SidebarMenuSub>
    </SidebarMenuItem>
  );
}
