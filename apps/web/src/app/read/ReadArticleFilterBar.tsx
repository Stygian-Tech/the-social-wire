"use client";

import { useState } from "react";

import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useReadSidebarScope } from "@/contexts/ReadSidebarScopeContext";
import { useCachedBulkReadActions } from "@/hooks/useCachedBulkReadActions";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { cn } from "@/lib/utils";

/**
 * Global All / Unread toggle for the read shell (applies to whichever publication is open).
 */
export function ReadArticleFilterBar() {
  const {
    setArticleListFilter,
    articleListFilter,
  } = useReadRoute();

  const { publicationsInSidebarTab } = useReadSidebarScope();
  const { bulkDisabled, applyMarkAllRead } =
    useCachedBulkReadActions(publicationsInSidebarTab);

  const [markAllReadOpen, setMarkAllReadOpen] = useState(false);

  return (
    <div className="ml-auto flex min-w-0 flex-1 items-center justify-end gap-2 sm:flex-none">
      <Button
            type="button"
            variant="outline"
            size="sm"
            className="min-w-0 flex-1 px-2 text-[11px] sm:flex-none"
            disabled={bulkDisabled}
            title={
              bulkDisabled
                ? "No cached articles yet — open publications or wait for the sidebar to prefetch"
                : undefined
            }
            onClick={() => setMarkAllReadOpen(true)}
          >
            Mark All As Read
          </Button>
          <Dialog open={markAllReadOpen} onOpenChange={setMarkAllReadOpen}>
            <DialogContent showCloseButton>
              <DialogHeader>
                <DialogTitle>Mark All As Read?</DialogTitle>
                <DialogDescription>
                  This marks every cached article for sources in your current sidebar tab as read.
                  Entries that have not been loaded yet stay unchanged until you open them.
                </DialogDescription>
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
      <div
        role="tablist"
        aria-label="Articles filter"
        className="flex shrink-0 rounded-2xl border border-border/80 bg-card/90 p-1 shadow-sm"
      >
        <button
          type="button"
          role="tab"
          id="read-shell-filter-all"
          aria-selected={articleListFilter === "all"}
          className={cn(
            "min-h-7 rounded-xl px-3 py-1 text-[11px] font-semibold transition-colors",
            articleListFilter === "all"
              ? "bg-primary text-primary-foreground shadow-sm"
              : "text-muted-foreground hover:bg-accent/70 hover:text-accent-foreground"
          )}
          onClick={() => setArticleListFilter("all")}
        >
          All
        </button>
        <button
          type="button"
          role="tab"
          id="read-shell-filter-unread"
          aria-selected={articleListFilter === "unread"}
          className={cn(
            "min-h-7 rounded-xl px-3 py-1 text-[11px] font-semibold transition-colors",
            articleListFilter === "unread"
              ? "bg-primary text-primary-foreground shadow-sm"
              : "text-muted-foreground hover:bg-accent/70 hover:text-accent-foreground"
          )}
          onClick={() => setArticleListFilter("unread")}
        >
          Unread
        </button>
      </div>
    </div>
  );
}
