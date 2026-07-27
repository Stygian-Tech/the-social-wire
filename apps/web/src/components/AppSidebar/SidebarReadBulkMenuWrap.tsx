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
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";

type SidebarDestructiveAction = {
  label: string;
  confirmationTitle: string;
  confirmationDescription: ReactNode;
  onConfirm: () => void;
  pending?: boolean;
};

type SidebarMenuAction = {
  label: string;
  onSelect: () => void;
  disabled?: boolean;
};

type SidebarReadBulkMenuWrapProps = {
  publications: DiscoveredPublication[];
  /** Shown in the confirmation dialog body for Mark All As Read */
  markAllReadConfirmation: ReactNode;
  gatewayScopes?: GatewayMarkAllReadScope[];
  children: ReactNode;
  showMarkAllUnread?: boolean;
  menuActions?: SidebarMenuAction[];
  destructiveAction?: SidebarDestructiveAction;
};

/**
 * Right-click (context) menu for bulk read/unread on cached sidebar entries.
 * Mark All As Read requires confirmation.
 */
export function SidebarReadBulkMenuWrap({
  publications,
  markAllReadConfirmation,
  gatewayScopes,
  children,
  showMarkAllUnread = true,
  menuActions,
  destructiveAction,
}: SidebarReadBulkMenuWrapProps) {
  const {
    bulkDisabled,
    applyMarkAllRead,
    applyMarkAllUnread,
  } = useCachedBulkReadActions(publications, { gatewayScopes });

  const [markAllReadOpen, setMarkAllReadOpen] = useState(false);
  const [destructiveOpen, setDestructiveOpen] = useState(false);

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
          {showMarkAllUnread ? (
            <>
              <ContextMenuSeparator />
              <ContextMenuItem
                disabled={bulkDisabled}
                className="gap-2"
                onClick={() => applyMarkAllUnread()}
              >
                Mark All As Unread
              </ContextMenuItem>
            </>
          ) : null}
          {menuActions?.length ? (
            <>
              <ContextMenuSeparator />
              {menuActions.map((action) => (
                <ContextMenuItem
                  key={action.label}
                  disabled={action.disabled}
                  className="gap-2"
                  onClick={action.onSelect}
                >
                  {action.label}
                </ContextMenuItem>
              ))}
            </>
          ) : null}
          {destructiveAction ? (
            <>
              <ContextMenuSeparator />
              <ContextMenuItem
                variant="destructive"
                disabled={destructiveAction.pending}
                className="gap-2"
                onClick={() => setDestructiveOpen(true)}
              >
                {destructiveAction.label}
              </ContextMenuItem>
            </>
          ) : null}
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
      {destructiveAction ? (
        <Dialog open={destructiveOpen} onOpenChange={setDestructiveOpen}>
          <DialogContent showCloseButton>
            <DialogHeader>
              <DialogTitle>{destructiveAction.confirmationTitle}</DialogTitle>
              <DialogDescription>
                {destructiveAction.confirmationDescription}
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={destructiveAction.pending}
                onClick={() => setDestructiveOpen(false)}
              >
                Cancel
              </Button>
              <Button
                type="button"
                variant="destructive"
                disabled={destructiveAction.pending}
                onClick={() => {
                  destructiveAction.onConfirm();
                  setDestructiveOpen(false);
                }}
              >
                {destructiveAction.label}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      ) : null}
    </>
  );
}
