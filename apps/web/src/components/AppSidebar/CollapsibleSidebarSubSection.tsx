"use client";

import { useId, type ReactNode } from "react";
import { ChevronRight } from "lucide-react";
import {
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
} from "@/components/ui/sidebar";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";
import { cn } from "@/lib/utils";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import { UnreadSidebarBadge } from "./UnreadSidebarBadge";

export function CollapsibleSidebarSubSection({
  title,
  unreadCount = 0,
  expanded,
  onToggle,
  subAriaLabel,
  readBulkPublications,
  readBulkMarkAllReadConfirmation,
  gatewayMarkAllReadScopes,
  children,
}: {
  title: string;
  unreadCount?: number;
  expanded: boolean;
  onToggle: () => void;
  subAriaLabel: string;
  readBulkPublications?: DiscoveredPublication[];
  /** Required when `readBulkPublications` is provided */
  readBulkMarkAllReadConfirmation?: ReactNode;
  gatewayMarkAllReadScopes?: GatewayMarkAllReadScope[];
  children: ReactNode;
}) {
  const subId = `sidebar-collapsible-sub-${useId().replace(/:/g, "")}`;

  const toggleButton = (
    <SidebarMenuButton
      type="button"
      onClick={onToggle}
      aria-expanded={expanded}
      aria-controls={subId}
      className={cn("gap-2", unreadCount > 0 && "relative pr-8")}
    >
      <ChevronRight
        className={cn(
          "size-4 shrink-0 transition-transform",
          expanded && "rotate-90"
        )}
        aria-hidden
      />
      <span className="min-w-0 flex-1 truncate text-left text-xs font-medium">
        {title}
      </span>
      <UnreadSidebarBadge count={unreadCount} />
    </SidebarMenuButton>
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
          {toggleButton}
        </SidebarReadBulkMenuWrap>
      ) : (
        toggleButton
      )}
      {expanded ? (
        <SidebarMenuSub
          id={subId}
          aria-label={subAriaLabel}
          className="mt-1.5"
        >
          {children}
        </SidebarMenuSub>
      ) : null}
    </SidebarMenuItem>
  );
}
