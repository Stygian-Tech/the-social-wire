"use client";

import { useReadRoute } from "@/contexts/ReadRouteContext";
import { cn } from "@/lib/utils";

/**
 * Global All / Unread toggle for the read shell (applies to whichever publication is open).
 */
export function ReadArticleFilterBar() {
  const {
    setArticleListFilter,
    isHiddenFolderContext,
    effectiveArticleListFilter,
  } = useReadRoute();

  const canFilterUnread = !isHiddenFolderContext;

  return (
    <div
      role="tablist"
      aria-label="Articles filter"
      className="ml-auto flex shrink-0 rounded-md border border-border/80 bg-background p-0.5"
    >
      <button
        type="button"
        role="tab"
        id="read-shell-filter-all"
        aria-selected={effectiveArticleListFilter === "all"}
        className={cn(
          "rounded px-2 py-1 text-[11px] font-medium transition-colors",
          effectiveArticleListFilter === "all"
            ? "bg-muted text-foreground"
            : "text-muted-foreground hover:bg-muted/60"
        )}
        onClick={() => setArticleListFilter("all")}
      >
        All
      </button>
      <button
        type="button"
        role="tab"
        id="read-shell-filter-unread"
        aria-selected={effectiveArticleListFilter === "unread"}
        disabled={!canFilterUnread}
        title={
          !canFilterUnread
            ? "Unread filter is not available for hidden publications"
            : undefined
        }
        className={cn(
          "rounded px-2 py-1 text-[11px] font-medium transition-colors",
          !canFilterUnread && "cursor-not-allowed opacity-50",
          effectiveArticleListFilter === "unread" && canFilterUnread
            ? "bg-muted text-foreground"
            : "text-muted-foreground hover:bg-muted/60"
        )}
        onClick={() => {
          if (canFilterUnread) setArticleListFilter("unread");
        }}
      >
        Unread
      </button>
    </div>
  );
}
