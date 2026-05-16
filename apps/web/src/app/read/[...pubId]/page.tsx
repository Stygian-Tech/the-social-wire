"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { use } from "react";
import { ChevronLeft } from "lucide-react";
import { EntryList } from "@/components/EntryList/EntryList";
import { EntryDetail } from "@/components/EntryDetail/EntryDetail";
import { Button } from "@/components/ui/button";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { readRoutePubIdFromSegments } from "@/lib/atprotoClient";
import { cn } from "@/lib/utils";

interface Props {
  params: Promise<{ pubId: string[] }>;
}

export default function PubPage({ params }: Props) {
  const { pubId: pubSegments } = use(params);
  const pubId = readRoutePubIdFromSegments(pubSegments);
  return <PubPageContent key={pubId} pubId={pubId} />;
}

function PubPageContent({ pubId }: { pubId: string }) {
  const [selectedEntryId, setSelectedEntryId] = useState<string | null>(null);
  const {
    markEntryRead,
    isEntryRead,
    isHiddenFolderContext,
    effectiveArticleListFilter,
  } = useReadRoute();

  const selectedRef = useRef<string | null>(null);
  const filterRef = useRef(effectiveArticleListFilter);
  useEffect(() => {
    selectedRef.current = selectedEntryId;
    filterRef.current = effectiveArticleListFilter;
  });

  const prevFilterRef = useRef(effectiveArticleListFilter);
  useEffect(() => {
    const prev = prevFilterRef.current;
    if (prev === "unread" && effectiveArticleListFilter === "all" && selectedEntryId) {
      markEntryRead(selectedEntryId);
    }
    prevFilterRef.current = effectiveArticleListFilter;
  }, [effectiveArticleListFilter, selectedEntryId, markEntryRead]);

  useEffect(() => {
    return () => {
      if (filterRef.current === "unread" && selectedRef.current) {
        markEntryRead(selectedRef.current);
      }
    };
  }, [pubId, markEntryRead]);

  const handleSelectEntry = useCallback(
    (entryId: string) => {
      if (effectiveArticleListFilter === "unread") {
        // Mark the previous open article read before switching — never call
        // markEntryRead inside setState's updater (that updates the parent
        // provider during a child state update and triggers a React warning).
        if (selectedEntryId && selectedEntryId !== entryId) {
          markEntryRead(selectedEntryId);
        }
        setSelectedEntryId(entryId);
        return;
      }
      setSelectedEntryId(entryId);
      markEntryRead(entryId);
    },
    [markEntryRead, effectiveArticleListFilter, selectedEntryId]
  );

  const handleBackToList = useCallback(() => {
    if (effectiveArticleListFilter === "unread" && selectedEntryId) {
      markEntryRead(selectedEntryId);
    }
    setSelectedEntryId(null);
  }, [effectiveArticleListFilter, selectedEntryId, markEntryRead]);

  return (
    <div className="flex h-full min-h-0 max-h-full flex-1 flex-col overflow-hidden md:flex-row md:items-stretch">
      {/* Article list — desktop: beside publications sidebar; mobile: full width until an entry opens */}
      <aside
        className={cn(
          "flex min-h-0 min-w-0 flex-col overflow-hidden border-r bg-muted/20",
          "w-full flex-1 md:h-full md:w-72 md:shrink-0 md:flex-none",
          selectedEntryId && "hidden md:flex"
        )}
      >
        <div className="shrink-0 border-b px-3 py-2">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
            Articles
          </p>
        </div>
        <div className="min-h-0 flex-1 overflow-hidden">
          <EntryList
            pubId={pubId}
            selectedEntryId={selectedEntryId}
            onSelectEntry={handleSelectEntry}
            isEntryRead={isEntryRead}
            readIndicatorsEnabled={!isHiddenFolderContext}
            articleFilter={effectiveArticleListFilter}
          />
        </div>
      </aside>

      {/* Entry detail */}
      <div
        className={cn(
          "flex min-h-0 min-w-0 flex-1 flex-col overflow-x-hidden overflow-y-auto overscroll-y-contain md:h-full",
          !selectedEntryId && "hidden md:flex"
        )}
      >
        {selectedEntryId ? (
          <>
            <div className="bg-background sticky top-0 z-10 flex min-h-[44px] shrink-0 items-center gap-2 border-b px-1 py-0 md:hidden">
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                className="size-11 shrink-0 rounded-lg"
                aria-label="Back to Articles"
                onClick={handleBackToList}
              >
                <ChevronLeft className="size-5" />
              </Button>
              <span className="text-sm font-medium text-muted-foreground">
                Articles
              </span>
            </div>
            <div className="flex min-h-0 flex-1 flex-col">
              <EntryDetail entryId={selectedEntryId} />
            </div>
          </>
        ) : (
          <div className="hidden flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground md:flex">
            Select an Article from the List
          </div>
        )}
      </div>
    </div>
  );
}
