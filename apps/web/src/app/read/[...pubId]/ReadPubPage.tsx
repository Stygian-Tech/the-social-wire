"use client";

import { useCallback, useMemo, useState } from "react";
import { EntryList } from "@/components/EntryList/EntryList";
import { RssArticleReaderDialog } from "@/components/EntryDetail/RssArticleReaderDialog";
import { DevRecordKindBadge } from "@/components/shared/DevRecordKindBadge";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { recordKindFromPubId } from "@/lib/recordKindDebug";
import { entryOpenTarget } from "@/lib/entryOpenTarget";
import type { EntryListItem } from "@/lib/atprotoClient";
import type { AggregateAppViewFeed } from "@/lib/thinAppViewClient";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";

export default function ReadPubPage({
  pubId,
  aggregateFeed,
}: {
  pubId?: string;
  aggregateFeed?: AggregateAppViewFeed;
}) {
  const [rssReaderEntry, setRssReaderEntry] = useState<{
    entryId: string;
    title: string;
    url: string;
  } | null>(null);
  const publicationKind = pubId ? recordKindFromPubId(pubId) : null;
  const { preferences } = useFeedDisplayPreferences();
  const {
    markEntryRead,
    markEntryUnread,
    isEntryRead,
    articleListFilter,
  } = useReadRoute();

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

  const handleSelectEntry = useCallback(
    (entryId: string, entry?: EntryListItem) => {
      if (!entry) return;
      const target = entryOpenTarget(entry, preferences.rssArticleOpenMode);
      if (!target) return;

      if (target.kind === "rssReader") {
        if (
          articleListFilter === "unread" &&
          rssReaderEntry &&
          rssReaderEntry.entryId !== entryId
        ) {
          markEntryReadForPub(rssReaderEntry.entryId);
        }
        setRssReaderEntry({
          entryId,
          title: entry?.title ?? "RSS Article",
          url: target.url,
        });
        if (articleListFilter !== "unread") {
          markEntryReadForPub(entryId);
        }
        return;
      }

      markEntryReadForPub(entryId);
      window.open(target.url, "_blank", "noopener,noreferrer");
    },
    [
      articleListFilter,
      markEntryReadForPub,
      preferences.rssArticleOpenMode,
      rssReaderEntry,
    ],
  );

  const closeRssReader = useCallback(() => {
    if (articleListFilter === "unread" && rssReaderEntry) {
      markEntryReadForPub(rssReaderEntry.entryId);
    }
    setRssReaderEntry(null);
  }, [articleListFilter, markEntryReadForPub, rssReaderEntry]);

  return (
    <>
      <div className="mx-auto flex h-full min-h-0 w-full flex-1 flex-col overflow-hidden bg-background">
        {publicationKind ? (
          <div className="shrink-0 px-3 pt-2">
            <DevRecordKindBadge info={publicationKind} />
          </div>
        ) : null}
        <div className="min-h-0 flex-1 overflow-hidden">
          <EntryList
            pubId={pubId}
            aggregateFeed={aggregateFeed}
            selectedEntryId={rssReaderEntry?.entryId ?? null}
            onSelectEntry={handleSelectEntry}
            isEntryRead={isEntryRead}
            readIndicatorsEnabled
            articleFilter={articleListFilter}
            markEntryRead={markEntryReadForPub}
            markEntryUnread={markEntryUnreadForPub}
          />
        </div>
      </div>
      <RssArticleReaderDialog
        open={rssReaderEntry !== null}
        entryId={rssReaderEntry?.entryId ?? null}
        originalUrl={rssReaderEntry?.url ?? null}
        title={rssReaderEntry?.title ?? ""}
        onClose={closeRssReader}
      />
    </>
  );
}
