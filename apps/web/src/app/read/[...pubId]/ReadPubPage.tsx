"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ChevronLeft } from "lucide-react";
import { EntryList } from "@/components/EntryList/EntryList";
import { EntryDetail } from "@/components/EntryDetail/EntryDetail";
import { DevRecordKindBadge } from "@/components/shared/DevRecordKindBadge";
import {
  READER_LIST_COLUMN_WIDTH_KEY,
  ResizableListColumn,
} from "@/components/shared/ResizableListColumn";
import { Button } from "@/components/ui/button";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { recordKindFromPubId } from "@/lib/recordKindDebug";
import { cn } from "@/lib/utils";

export default function ReadPubPage({ pubId }: { pubId: string }) {
  const [selectedEntryId, setSelectedEntryId] = useState<string | null>(null);
  const publicationKind = recordKindFromPubId(pubId);
  const {
    markEntryRead,
    markEntryUnread,
    isEntryRead,
    articleListFilter,
  } = useReadRoute();

  const selectedRef = useRef<string | null>(null);
  const filterRef = useRef(articleListFilter);
  useEffect(() => {
    selectedRef.current = selectedEntryId;
    filterRef.current = articleListFilter;
  });

  const markOptions = useMemo(() => ({ publicationId: pubId }), [pubId]);

  const markEntryReadForPub = useCallback(
    (entryId: string) => markEntryRead(entryId, markOptions),
    [markEntryRead, markOptions]
  );

  const markEntryUnreadForPub = useCallback(
    (entryId: string) => markEntryUnread(entryId, markOptions),
    [markEntryUnread, markOptions]
  );

  const prevFilterRef = useRef(articleListFilter);
  useEffect(() => {
    const prev = prevFilterRef.current;
    if (prev === "unread" && articleListFilter === "all" && selectedEntryId) {
      markEntryReadForPub(selectedEntryId);
    }
    prevFilterRef.current = articleListFilter;
  }, [articleListFilter, selectedEntryId, markEntryReadForPub]);

  useEffect(() => {
    return () => {
      if (filterRef.current === "unread" && selectedRef.current) {
        markEntryReadForPub(selectedRef.current);
      }
    };
  }, [pubId, markEntryReadForPub]);

  const handleSelectEntry = useCallback(
    (entryId: string) => {
      if (articleListFilter === "unread") {
        if (selectedEntryId && selectedEntryId !== entryId) {
          markEntryReadForPub(selectedEntryId);
        }
        setSelectedEntryId(entryId);
        return;
      }
      setSelectedEntryId(entryId);
      markEntryReadForPub(entryId);
    },
    [markEntryReadForPub, articleListFilter, selectedEntryId]
  );

  const handleBackToList = useCallback(() => {
    if (articleListFilter === "unread" && selectedEntryId) {
      markEntryReadForPub(selectedEntryId);
    }
    setSelectedEntryId(null);
  }, [articleListFilter, selectedEntryId, markEntryReadForPub]);

  return (
    <div className="flex h-full min-h-0 max-h-full flex-1 flex-col overflow-hidden md:flex-row md:items-stretch">
      {/* Article list — desktop: beside publications sidebar; mobile: full width until an entry opens */}
      <ResizableListColumn
        storageKey={READER_LIST_COLUMN_WIDTH_KEY}
        hiddenOnMobile={Boolean(selectedEntryId)}
      >
        <div className="shrink-0 border-b px-3 py-2">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
              Articles
            </p>
            <DevRecordKindBadge info={publicationKind} />
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-hidden">
          <EntryList
            pubId={pubId}
            selectedEntryId={selectedEntryId}
            onSelectEntry={handleSelectEntry}
            isEntryRead={isEntryRead}
            readIndicatorsEnabled
            articleFilter={articleListFilter}
            markEntryRead={markEntryReadForPub}
            markEntryUnread={markEntryUnreadForPub}
          />
        </div>
      </ResizableListColumn>

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
