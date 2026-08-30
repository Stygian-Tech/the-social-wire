"use client";

import dynamic from "next/dynamic";
import { useCallback, useMemo, useState } from "react";
import { EntryList } from "@/components/EntryList/EntryList";
import { RssArticleReaderDialog } from "@/components/EntryDetail/RssArticleReaderDialog";
import { DevRecordKindBadge } from "@/components/shared/DevRecordKindBadge";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { OUTBOUND_WINDOW_FEATURES } from "@/lib/outboundLinks";
import { recordKindFromPubId } from "@/lib/recordKindDebug";
import { entryOpenTarget, type EntryOpenTarget } from "@/lib/entryOpenTarget";
import { resolveEntryOpenUrlFromPds } from "@/lib/resolveEntryOpenUrl";
import type { EntryListItem } from "@/lib/atprotoClient";
import type { AggregateAppViewFeed } from "@/lib/thinAppViewClient";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import { useAuth } from "@/hooks/useAuth";
import { isWireNewsEditionEnabled } from "@/lib/wireEditionClient";

const ignoreTheWireReadState = () => undefined;
const theWireEntryIsUnread = () => false;

const WireNewsExperience = dynamic(
  () => import("@/components/Wire/WireNewsExperience"),
  {
    loading: () => (
      <div className="grid h-full gap-4 p-4 sm:grid-cols-2">
        <div className="h-80 animate-pulse rounded-2xl bg-muted" />
        <div className="h-80 animate-pulse rounded-2xl bg-muted" />
      </div>
    ),
  },
);

const CircleNewsExperience = dynamic(
  () => import("@/components/Circle/CircleNewsExperience"),
  {
    loading: () => (
      <div className="grid h-full gap-4 p-4 sm:grid-cols-2">
        <div className="h-80 animate-pulse rounded-2xl bg-muted" />
        <div className="h-80 animate-pulse rounded-2xl bg-muted" />
      </div>
    ),
  },
);

export default function ReadPubPage({
  pubId,
  aggregateFeed,
  wireFeed = false,
  circleFeed = false,
}: {
  pubId?: string;
  aggregateFeed?: AggregateAppViewFeed;
  wireFeed?: boolean;
  circleFeed?: boolean;
}) {
  const wireNewsEditionEnabled = wireFeed && isWireNewsEditionEnabled();
  const editorialFeed = wireFeed || circleFeed;
  const [rssReaderEntry, setRssReaderEntry] = useState<{
    entryId: string;
    title: string;
    url: string;
  } | null>(null);
  const [resolvingEntryId, setResolvingEntryId] = useState<string | null>(null);
  const [openFailureMessage, setOpenFailureMessage] = useState<string | null>(
    null,
  );
  const publicationKind = pubId ? recordKindFromPubId(pubId) : null;
  const { preferences } = useFeedDisplayPreferences();
  const { getOAuthSession } = useAuth();
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

  const openEntryTarget = useCallback(
    (
      entryId: string,
      entry: EntryListItem,
      target: EntryOpenTarget,
      pendingTab?: Window | null,
    ) => {
      if (target.kind === "rssReader") {
        pendingTab?.close();
        if (
          !editorialFeed &&
          articleListFilter === "unread" &&
          rssReaderEntry &&
          rssReaderEntry.entryId !== entryId
        ) {
          markEntryReadForPub(rssReaderEntry.entryId);
        }
        setRssReaderEntry({
          entryId,
          title: entry.title ?? "RSS Article",
          url: target.url,
        });
        if (!editorialFeed && articleListFilter !== "unread") {
          markEntryReadForPub(entryId);
        }
        return;
      }

      if (!editorialFeed) markEntryReadForPub(entryId);
      if (pendingTab) {
        pendingTab.location.href = target.url;
        return;
      }
      window.open(target.url, "_blank", OUTBOUND_WINDOW_FEATURES);
    },
    [articleListFilter, editorialFeed, markEntryReadForPub, rssReaderEntry],
  );

  const handleSelectEntry = useCallback(
    (entryId: string, entry?: EntryListItem) => {
      if (!entry) return;
      setOpenFailureMessage(null);
      const target = entryOpenTarget(entry, preferences.rssArticleOpenMode);
      if (target) {
        openEntryTarget(entryId, entry, target);
        return;
      }

      // The AppView has no indexed URL for this entry, so fall back to the author's PDS. Claim
      // the tab synchronously — after an `await` the user gesture is gone and Safari blocks it.
      // `noopener`/`noreferrer` in the features string make window.open return null, which would
      // lose the handle we need to navigate it, so sever the opener by hand instead. The tab is
      // still about:blank here, so it inherits our origin and the assignment sticks.
      const pendingTab = window.open("", "_blank");
      if (pendingTab) pendingTab.opener = null;
      setResolvingEntryId(entryId);
      void (async () => {
        let resolvedUrl: string | undefined;
        try {
          resolvedUrl = await resolveEntryOpenUrlFromPds(
            entryId,
            getOAuthSession() ?? undefined,
          );
        } finally {
          setResolvingEntryId(null);
        }

        const resolvedTarget = resolvedUrl
          ? entryOpenTarget(
              { ...entry, originalUrl: resolvedUrl },
              preferences.rssArticleOpenMode,
            )
          : null;
        if (!resolvedTarget) {
          pendingTab?.close();
          setOpenFailureMessage("Couldn't Find A Link For This Article.");
          return;
        }
        openEntryTarget(entryId, entry, resolvedTarget, pendingTab);
      })();
    },
    [
      getOAuthSession,
      openEntryTarget,
      preferences.rssArticleOpenMode,
    ],
  );

  const closeRssReader = useCallback(() => {
    if (!editorialFeed && articleListFilter === "unread" && rssReaderEntry) {
      markEntryReadForPub(rssReaderEntry.entryId);
    }
    setRssReaderEntry(null);
  }, [articleListFilter, editorialFeed, markEntryReadForPub, rssReaderEntry]);

  return (
    <>
      <div className="mx-auto flex h-full min-h-0 w-full flex-1 flex-col overflow-hidden bg-background">
        {publicationKind ? (
          <div className="shrink-0 px-3 pt-2">
            <DevRecordKindBadge info={publicationKind} />
          </div>
        ) : null}
        {openFailureMessage ? (
          <div className="shrink-0 px-3 pt-2">
            <div
              role="status"
              aria-live="polite"
              className="flex items-center justify-between gap-3 rounded-xl border border-border bg-muted/35 px-4 py-3 text-sm text-muted-foreground"
            >
              <span>{openFailureMessage}</span>
              <button
                type="button"
                className="shrink-0 text-primary underline-offset-4 hover:underline"
                onClick={() => setOpenFailureMessage(null)}
              >
                Dismiss
              </button>
            </div>
          </div>
        ) : null}
        <div className="min-h-0 flex-1 overflow-hidden">
          {circleFeed ? (
            <CircleNewsExperience onSelect={handleSelectEntry} />
          ) : wireNewsEditionEnabled ? (
            <WireNewsExperience onSelect={handleSelectEntry} />
          ) : (
            <EntryList
              pubId={pubId}
              aggregateFeed={aggregateFeed}
              wireFeed={wireFeed}
              selectedEntryId={rssReaderEntry?.entryId ?? null}
              resolvingEntryId={resolvingEntryId}
              onSelectEntry={handleSelectEntry}
              isEntryRead={editorialFeed ? theWireEntryIsUnread : isEntryRead}
              readIndicatorsEnabled={!editorialFeed}
              articleFilter={editorialFeed ? "all" : articleListFilter}
              markEntryRead={
                editorialFeed ? ignoreTheWireReadState : markEntryReadForPub
              }
              markEntryUnread={
                editorialFeed ? ignoreTheWireReadState : markEntryUnreadForPub
              }
            />
          )}
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
