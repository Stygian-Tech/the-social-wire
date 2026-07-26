"use client";

import {
  memo,
  useCallback,
  useState,
  type CSSProperties,
  type KeyboardEvent,
} from "react";
import { useWebHaptics } from "web-haptics/react";
import { PublicationLeadingAvatar } from "./PublicationLeadingAvatar";
import { PublicationSubItemActions } from "./PublicationSubItemActions";
import { ContextMenu, ContextMenuTrigger } from "@/components/ui/context-menu";
import {
  SidebarMenuBadge,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
} from "@/components/ui/sidebar";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type {
  FolderRecord,
  PublicationPrefsRecord,
  RepoRecord,
} from "@/lib/pdsClient";
import { rkeyFromURI } from "@/lib/pdsClient";
import { cn } from "@/lib/utils";

export type PublicationSidebarTab = "following" | "subscribed";

export interface PublicationSubItemProps {
  publication: DiscoveredPublication;
  /** Cache-only unread count from {@link useSidebarUnreadCounts}. */
  unreadCount: number;
  isSelected: boolean;
  onSelect: (publicationId: string) => void;
  folders: RepoRecord<FolderRecord>[];
  prefsMap: Map<string, RepoRecord<PublicationPrefsRecord>>;
  sidebarTab: PublicationSidebarTab;
  className?: string;
  style?: CSSProperties;
}

function PublicationSubItemInner({
  publication,
  unreadCount,
  isSelected,
  onSelect,
  folders,
  prefsMap,
  sidebarTab,
  className,
  style,
}: PublicationSubItemProps) {
  const { trigger, isSupported } = useWebHaptics();
  const [actionsMounted, setActionsMounted] = useState(false);

  const hapticLight = useCallback(() => {
    if (isSupported) void trigger("light");
  }, [isSupported, trigger]);

  const hapticSuccess = useCallback(() => {
    if (isSupported) void trigger("success");
  }, [isSupported, trigger]);

  const activateActions = useCallback(() => {
    setActionsMounted(true);
  }, []);

  const handleOpenChange = useCallback(
    (open: boolean) => {
      if (!open) return;
      activateActions();
      hapticLight();
    },
    [activateActions, hapticLight],
  );

  const handleTriggerKeyDown = useCallback(
    (event: KeyboardEvent) => {
      if (
        event.key === "ContextMenu" ||
        (event.shiftKey && event.key === "F10")
      ) {
        activateActions();
      }
    },
    [activateActions],
  );

  return (
    <SidebarMenuSubItem
      className={cn(
        "[content-visibility:auto] [contain-intrinsic-size:30px]",
        className,
      )}
      style={style}
    >
      <ContextMenu onOpenChange={handleOpenChange}>
        <ContextMenuTrigger
          className="flex min-w-0 w-full data-popup-open:bg-sidebar-accent"
          onContextMenu={activateActions}
          onKeyDown={handleTriggerKeyDown}
        >
          <SidebarMenuSubButton
            size="md"
            isActive={isSelected}
            render={<button type="button" />}
            onClick={() => onSelect(publication.publicationId)}
            className="relative min-w-0 flex-1 gap-2 pr-8"
          >
            <PublicationLeadingAvatar publication={publication} />
            <div className="flex min-w-0 flex-1 items-center">
              <span className="w-full truncate">{publication.title}</span>
            </div>
            <SidebarMenuBadge
              className={cn(
                "top-1/2 -translate-y-1/2",
                unreadCount <= 0 && "pointer-events-none opacity-0",
              )}
              aria-hidden={unreadCount <= 0}
              aria-label={unreadCount > 0 ? `${unreadCount} unread` : undefined}
            >
              {unreadCount > 0 ? unreadCount : 0}
            </SidebarMenuBadge>
          </SidebarMenuSubButton>
        </ContextMenuTrigger>
        {actionsMounted ? (
          <PublicationSubItemActions
            publication={publication}
            folders={folders}
            prefsMap={prefsMap}
            sidebarTab={sidebarTab}
            onHapticSuccess={hapticSuccess}
          />
        ) : null}
      </ContextMenu>
    </SidebarMenuSubItem>
  );
}

function folderSignature(folders: RepoRecord<FolderRecord>[]): string {
  return folders
    .map((folder) => `${rkeyFromURI(folder.uri)}:${folder.value.name ?? ""}`)
    .join("|");
}

function publicationSubItemPropsEqual(
  prev: PublicationSubItemProps,
  next: PublicationSubItemProps,
): boolean {
  const prevPub = prev.publication;
  const nextPub = next.publication;
  return (
    prev.unreadCount === next.unreadCount &&
    prev.isSelected === next.isSelected &&
    prev.onSelect === next.onSelect &&
    prev.sidebarTab === next.sidebarTab &&
    prev.className === next.className &&
    prev.style === next.style &&
    prevPub.publicationId === nextPub.publicationId &&
    prevPub.subscriptionPublicationId === nextPub.subscriptionPublicationId &&
    prevPub.authorDid === nextPub.authorDid &&
    prevPub.authorHandle === nextPub.authorHandle &&
    prevPub.title === nextPub.title &&
    prevPub.iconUrl === nextPub.iconUrl &&
    prevPub.avatarUrl === nextPub.avatarUrl &&
    prev.prefsMap.get(prevPub.publicationId)?.value.folderId ===
      next.prefsMap.get(nextPub.publicationId)?.value.folderId &&
    folderSignature(prev.folders) === folderSignature(next.folders)
  );
}

export const PublicationSubItem = memo(
  PublicationSubItemInner,
  publicationSubItemPropsEqual,
);
