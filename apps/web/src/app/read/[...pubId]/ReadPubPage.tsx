"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { EntryList } from "@/components/EntryList/EntryList";
import { EntryDetail } from "@/components/EntryDetail/EntryDetail";
import { ReaderPaneHeader } from "@/components/EntryDetail/ReaderPaneHeader";
import { DevRecordKindBadge } from "@/components/shared/DevRecordKindBadge";
import {
  READER_LIST_COLUMN_WIDTH_KEY,
  ResizableListColumn,
} from "@/components/shared/ResizableListColumn";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useEntry } from "@/hooks/useEntries";
import { useIsTabletPortrait } from "@/hooks/use-tablet-portrait";
import { shouldShowArticleListColumn } from "@/lib/readerColumnVisibility";
import { recordKindFromPubId } from "@/lib/recordKindDebug";
import { cn } from "@/lib/utils";
import type { AggregateAppViewFeed } from "@/lib/thinAppViewClient";

export default function ReadPubPage({
  pubId,
  aggregateFeed,
  title = "Articles",
}: {
  pubId?: string;
  aggregateFeed?: AggregateAppViewFeed;
  title?: string;
}) {
  const [selectedEntryId, setSelectedEntryId] = useState<string | null>(null);
  const { data: selectedEntry } = useEntry(selectedEntryId);
  const publicationKind = pubId ? recordKindFromPubId(pubId) : null;
  const {
    markEntryRead,
    markEntryUnread,
    isEntryRead,
    articleListFilter,
    isArticleListColumnOpen,
  } = useReadRoute();
  const isTabletPortrait = useIsTabletPortrait();
  const showsArticleListColumn = shouldShowArticleListColumn({
    isTabletPortrait,
    isOpenInTabletPortrait: isArticleListColumnOpen,
  });

  const selectedRef = useRef<string | null>(null);
  const filterRef = useRef(articleListFilter);
  useEffect(() => {
    selectedRef.current = selectedEntryId;
    filterRef.current = articleListFilter;
  });

  const markOptions = useMemo(
    () => (pubId ? { publicationId: pubId } : undefined),
    [pubId],
  );

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
  }, [aggregateFeed?.id, aggregateFeed?.kind, pubId, markEntryReadForPub]);

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
        className={!showsArticleListColumn ? "md:hidden" : undefined}
      >
        <div className="shrink-0 border-b bg-background/75 px-3 py-2 backdrop-blur-md">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">
              {title}
            </p>
            {publicationKind ? (
              <DevRecordKindBadge info={publicationKind} />
            ) : null}
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-hidden">
          <EntryList
            pubId={pubId}
            aggregateFeed={aggregateFeed}
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
          "flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden md:h-full",
          !selectedEntryId && "hidden md:flex"
        )}
      >
        {selectedEntryId ? (
          <>
            <ReaderPaneHeader
              entry={selectedEntry}
              fallbackTitle="Loading Article…"
              onBack={handleBackToList}
            />
            <div className="flex min-h-0 flex-1 flex-col overflow-y-auto overflow-x-hidden overscroll-y-contain">
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
