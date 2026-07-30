"use client";

import { useState } from "react";
import { List, ListCollapse } from "lucide-react";

import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useReadSidebarScope } from "@/contexts/ReadSidebarScopeContext";
import { useCachedBulkReadActions } from "@/hooks/useCachedBulkReadActions";
import { useIsTabletPortrait } from "@/hooks/use-tablet-portrait";
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
    isArticleListColumnOpen,
    setIsArticleListColumnOpen,
  } = useReadRoute();
  const isTabletPortrait = useIsTabletPortrait();

  const { activeFeedScope } = useReadSidebarScope();
  const { bulkDisabled, applyMarkAllRead } =
    useCachedBulkReadActions(activeFeedScope.publications, {
      gatewayScopes: activeFeedScope.gatewayScope
        ? [activeFeedScope.gatewayScope]
        : [],
    });

  const [markAllReadOpen, setMarkAllReadOpen] = useState(false);
  const markAllReadDisabled =
    bulkDisabled || !activeFeedScope.displayName.trim();

  return (
    <div className="ml-auto flex min-w-0 flex-1 items-center justify-end gap-2 sm:flex-none">
      {isTabletPortrait ? (
        <Button
          type="button"
          variant="ghost"
          size="sm"
          className="min-h-11 shrink-0 gap-1.5 rounded-md border-0 bg-transparent px-2 text-[11px] font-semibold text-muted-foreground shadow-none hover:bg-muted/50 hover:text-foreground"
          aria-label={
            isArticleListColumnOpen ? "Hide Articles" : "Show Articles"
          }
          aria-pressed={!isArticleListColumnOpen}
          onClick={() =>
            setIsArticleListColumnOpen(!isArticleListColumnOpen)
          }
        >
          {isArticleListColumnOpen ? (
            <ListCollapse aria-hidden="true" className="size-4" />
          ) : (
            <List aria-hidden="true" className="size-4" />
          )}
          {isArticleListColumnOpen ? "Hide Articles" : "Show Articles"}
        </Button>
      ) : null}
      <Button
            type="button"
            variant="ghost"
            size="sm"
            className="min-w-0 flex-1 rounded-md border-0 bg-transparent px-2 text-[11px] font-semibold text-muted-foreground shadow-none hover:bg-muted/50 hover:text-foreground sm:flex-none"
            disabled={markAllReadDisabled}
            onClick={() => setMarkAllReadOpen(true)}
          >
            Mark All As Read
          </Button>
          <Dialog open={markAllReadOpen} onOpenChange={setMarkAllReadOpen}>
            <DialogContent showCloseButton>
              <DialogHeader>
                <DialogTitle>Mark All As Read?</DialogTitle>
                <DialogDescription>
                  This marks every unread article in{" "}
                  <span className="font-medium text-foreground">
                    {activeFeedScope.displayName}
                  </span>{" "}
                  as read.
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
                  disabled={markAllReadDisabled}
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
        className="flex shrink-0 items-center gap-1"
      >
        <button
          type="button"
          role="tab"
          id="read-shell-filter-all"
          aria-selected={articleListFilter === "all"}
          className={cn(
            "relative min-h-7 rounded-md px-2.5 py-1 text-[11px] font-semibold text-muted-foreground transition-colors after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:rounded-full after:bg-transparent hover:bg-muted/50 hover:text-foreground",
            articleListFilter === "all"
              ? "text-[var(--purple-foreground)] after:bg-primary"
              : ""
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
            "relative min-h-7 rounded-md px-2.5 py-1 text-[11px] font-semibold text-muted-foreground transition-colors after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:rounded-full after:bg-transparent hover:bg-muted/50 hover:text-foreground",
            articleListFilter === "unread"
              ? "text-[var(--purple-foreground)] after:bg-primary"
              : ""
          )}
          onClick={() => setArticleListFilter("unread")}
        >
          Unread
        </button>
      </div>
    </div>
  );
}
