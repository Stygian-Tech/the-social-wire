"use client";

import { useMemo } from "react";

import { ArticleSocialToolbar } from "@/components/EntryDetail/ArticleSocialToolbar";
import type { EntryDetail, EntryListItem } from "@/lib/atprotoClient";

export function EntryCardActionMenu({
  entry,
  showWireFeedback = false,
}: {
  entry: EntryListItem;
  showWireFeedback?: boolean;
}) {
  const actionEntry = useMemo<EntryDetail>(
    () => ({
      entryId: entry.entryId,
      title: entry.title,
      summary: entry.summary,
      publishedAt: entry.publishedAt,
      contentHtml: entry.summary ?? "",
      thumbnailUrl: entry.thumbnailUrl,
      thumbnailFallbackUrl: entry.thumbnailFallbackUrl,
      originalUrl: entry.originalUrl,
      embedUrl: entry.originalUrl,
      ...(entry.wireItem?.representativeUri
        ? { entryId: entry.wireItem.representativeUri }
        : {}),
    }),
    [entry],
  );

  return (
    <div
      className="flex items-center"
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => event.stopPropagation()}
    >
      <ArticleSocialToolbar
        entry={actionEntry}
        variant="menu"
        className="size-8"
        showWireFeedback={showWireFeedback}
      />
    </div>
  );
}
