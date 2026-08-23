"use client";

import { useState } from "react";
import { List, ListCollapse, RefreshCw } from "lucide-react";
import { usePathname, useSearchParams } from "next/navigation";

import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useReadSidebarScope } from "@/contexts/ReadSidebarScopeContext";
import { useCachedBulkReadActions } from "@/hooks/useCachedBulkReadActions";
import { useIsTabletPortrait } from "@/hooks/use-tablet-portrait";
import { useClientHydrated } from "@/hooks/useClientHydrated";
import { useSidebarBootstrap } from "@/contexts/PublicationSidebarContext";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
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
import { useWireEdition } from "@/hooks/useWireEdition";
import { useWireFeedEntries } from "@/hooks/useWireFeed";
import { isWireNewsEditionEnabled } from "@/lib/wireEditionClient";
import { WireAlphaBadge } from "@/components/Wire/WireAlphaBadge";

export function readFeedHeaderClassName(isWire: boolean) {
  return isWire ? "pt-3" : undefined;
}

/**
 * Global All / Unread toggle for the read shell (applies to whichever publication is open).
 */
export function ReadArticleFilterBar() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const {
    setArticleListFilter,
    articleListFilter,
    isArticleListColumnOpen,
    setIsArticleListColumnOpen,
  } = useReadRoute();
  const isTabletPortrait = useIsTabletPortrait();
  const clientHydrated = useClientHydrated();
  const { refresh } = useSidebarBootstrap();
  const isWire =
    pathname === "/read" && searchParams.get("feed") === "wire";
  const wireNewsEditionEnabled = isWire && isWireNewsEditionEnabled();
  const wireEdition = useWireEdition({ enabled: wireNewsEditionEnabled });
  const wireFeed = useWireFeedEntries({
    enabled: isWire && !wireNewsEditionEnabled,
  });
  const wire = wireNewsEditionEnabled ? wireEdition : wireFeed;

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
  const routeFeedTitle = pathname === "/read"
    ? searchParams.get("folder")
      ? "Folder"
      : searchParams.get("feed") === "following"
        ? "Following"
        : "Subscribed"
    : "Articles";
  const feedTitle = activeFeedScope.displayName.trim() || routeFeedTitle;

  if (isWire) {
    return (
      <FeedHeader
        title={
          <span
            aria-label="The Wire, Alpha"
            className="inline-flex items-center gap-2"
          >
            <span>The Wire</span>
            <WireAlphaBadge />
          </span>
        }
        className={readFeedHeaderClassName(isWire)}
      >
        <Button
          type="button"
          variant="ghost"
          size="icon-sm"
          className="size-8 shrink-0 rounded-md border-0 bg-transparent shadow-none hover:bg-muted/50 hover:text-foreground"
          disabled={
            wire.isRefreshingFirstPage ||
            wire.isLoading ||
            wire.viewerModerationRetryUnavailable
          }
          aria-label="Refresh The Wire"
          title="Refresh The Wire"
          onClick={() => {
            void wire.retryTheWire().catch(() => undefined);
          }}
        >
          <RefreshCw
            aria-hidden="true"
            className={`size-3.5 ${wire.isRefreshingFirstPage ? "animate-spin" : ""}`}
          />
        </Button>
      </FeedHeader>
    );
  }

  return (
    <FeedHeader title={feedTitle}>
      <div className="ml-auto flex shrink-0 items-center gap-1">
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
          className="min-w-0 shrink-0 rounded-md border-0 bg-transparent px-2 text-[11px] font-semibold text-muted-foreground shadow-none hover:bg-muted/50 hover:text-foreground"
          disabled={clientHydrated ? markAllReadDisabled : undefined}
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
                : "",
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
                : "",
            )}
            onClick={() => setArticleListFilter("unread")}
          >
            Unread
          </button>
        </div>
        <Button
          type="button"
          variant="ghost"
          size="icon-sm"
          className="size-8 shrink-0 rounded-md border-0 bg-transparent shadow-none hover:bg-muted/50 hover:text-foreground"
          onClick={() => refresh.mutate()}
          disabled={refresh.isPending}
          aria-label="Refresh Publications"
          title="Refresh Publications"
        >
          <RefreshCw
            aria-hidden="true"
            className={`size-3.5 ${refresh.isPending ? "animate-spin" : ""}`}
          />
        </Button>
      </div>
    </FeedHeader>
  );
}
