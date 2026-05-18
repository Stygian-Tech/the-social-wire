"use client";

import { type ReactNode, useState } from "react";

import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { useCachedBulkReadActions } from "@/hooks/useCachedBulkReadActions";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

type SidebarReadBulkMenuWrapProps = {
  publications: DiscoveredPublication[];
  /** Shown in the confirmation dialog body for Mark All As Read */
  markAllReadConfirmation: ReactNode;
  children: ReactNode;
};

/**
 * Right-click (context) menu for bulk read/unread on cached sidebar entries.
 * Mark All As Read requires confirmation.
 */
export function SidebarReadBulkMenuWrap({
  publications,
  markAllReadConfirmation,
  children,
}: SidebarReadBulkMenuWrapProps) {
  const {
    bulkDisabled,
    applyMarkAllRead,
    applyMarkAllUnread,
  } = useCachedBulkReadActions(publications);

  const [markAllReadOpen, setMarkAllReadOpen] = useState(false);

  return (
    <>
      <ContextMenu>
        <ContextMenuTrigger className="flex min-w-0 w-full outline-none">
          {children}
        </ContextMenuTrigger>
        <ContextMenuContent className="min-w-[11rem]">
          <ContextMenuItem
            disabled={bulkDisabled}
            className="gap-2"
            onClick={() => setMarkAllReadOpen(true)}
          >
            Mark All As Read
          </ContextMenuItem>
          <ContextMenuSeparator />
          <ContextMenuItem
            disabled={bulkDisabled}
            className="gap-2"
            onClick={() => applyMarkAllUnread()}
          >
            Mark All As Unread
          </ContextMenuItem>
        </ContextMenuContent>
      </ContextMenu>
      <Dialog open={markAllReadOpen} onOpenChange={setMarkAllReadOpen}>
        <DialogContent showCloseButton>
          <DialogHeader>
            <DialogTitle>Mark All As Read?</DialogTitle>
            <DialogDescription>{markAllReadConfirmation}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setMarkAllReadOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              disabled={bulkDisabled}
              onClick={() => {
                applyMarkAllRead();
                setMarkAllReadOpen(false);
              }}
            >
              Mark All As Read
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
