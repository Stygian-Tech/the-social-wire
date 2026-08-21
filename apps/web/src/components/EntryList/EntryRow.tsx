"use client";

import { memo, useMemo, useState } from "react";
import { EntryCardActionMenu } from "@/components/EntryList/EntryCardActionMenu";
import { EntryRowActions } from "@/components/EntryList/EntryRowActions";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import { thumbnailImageSrcAttempts } from "@/lib/publicResourceUrl";
import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";
import { cn } from "@/lib/utils";
import type { EntryListItem } from "@/lib/atprotoClient";
import { CachedImage } from "@/components/shared/CachedImage";
import {
  articleListCardHorizontalWrapperClassName,
  articleListRowButtonClassName,
} from "@/lib/articleListCardStyles";
import { PublicationChip } from "@/components/shared/PublicationChip";
import { useOptionalSidebarPublicationRows } from "@/contexts/PublicationSidebarContext";
import {
  wireProvenanceLabel,
  wireReasonLabel,
} from "@/lib/wireFeedClient";

interface EntryRowProps {
  entry: EntryListItem;
  isSelected: boolean;
  /** True while the row's destination is being resolved from the PDS after a click. */
  isResolving?: boolean;
  onSelect: (entryId: string, entry?: EntryListItem) => void;
  isRead: boolean;
  readIndicatorsEnabled: boolean;
  onMarkEntryRead: (entryId: string) => void;
  onMarkEntryUnread: (entryId: string) => void;
  publication?: { name: string; faviconUrl?: string };
}

export const EntryRow = memo(function EntryRow({
  entry,
  isSelected,
  isResolving = false,
  onSelect,
  isRead,
  readIndicatorsEnabled,
  onMarkEntryRead,
  onMarkEntryUnread,
  publication: publicationOverride,
}: EntryRowProps) {
  const date = new Date(entry.publishedAt);
  const formattedDate = date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year:
      date.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined,
  });

  const showUnreadChrome = readIndicatorsEnabled && !isRead;
  const thumbAttempts = useMemo(
    () =>
      thumbnailImageSrcAttempts(entry.thumbnailUrl, entry.thumbnailFallbackUrl),
    [entry.thumbnailUrl, entry.thumbnailFallbackUrl],
  );
  const displayTitle = useMemo(
    () => decodeHtmlEntities(entry.title),
    [entry.title],
  );
  const displaySummary = useMemo(
    () => (entry.summary ? decodeHtmlEntities(entry.summary) : undefined),
    [entry.summary],
  );
  const [attemptIdx, setAttemptIdx] = useState(0);
  const allPublicationRows = useOptionalSidebarPublicationRows();
  const sidebarPublication = entry.publicationId
    ? allPublicationRows.find(
        (row) => row.publicationId === entry.publicationId,
      )
    : undefined;
  const publication =
    (entry.wireItem
      ? {
          name:
            entry.wireItem.source.publication?.trim() ||
            entry.wireItem.source.name.trim() ||
            entry.wireItem.source.domain,
        }
      : publicationOverride) ??
    (sidebarPublication
      ? {
          name: sidebarPublication.title,
          faviconUrl:
            sidebarPublication.iconUrl ?? sidebarPublication.avatarUrl,
        }
      : undefined);
  const showPublishedDate =
    !entry.wireItem || Boolean(entry.wireItem.publishedAt?.trim());
  const wireReasonLabels = (entry.wireItem?.reasons ?? [])
    .map(wireReasonLabel)
    .filter((label): label is string => Boolean(label));
  const wireProvenance = (entry.wireItem?.provenance ?? [])
    .map(wireProvenanceLabel)
    .filter((label): label is string => Boolean(label))
    .slice(0, 2);
  const activeThumbSrc =
    thumbAttempts.length > 0 && attemptIdx < thumbAttempts.length
      ? thumbAttempts[attemptIdx]
      : undefined;
  const thumbsExhausted =
    thumbAttempts.length > 0 && attemptIdx >= thumbAttempts.length;
  const showThumb = Boolean(activeThumbSrc) && !thumbsExhausted;

  const rowButton = (
    <div
      className={cn(
        "group/entry-row relative",
        articleListCardHorizontalWrapperClassName,
      )}
    >
      <div
        role="button"
        tabIndex={0}
        data-at-uri={entry.entryId}
        aria-busy={isResolving || undefined}
        onClick={() => onSelect(entry.entryId, entry)}
        onKeyDown={(event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          event.preventDefault();
          onSelect(entry.entryId, entry);
        }}
        className={cn(
          articleListRowButtonClassName({
            isSelected,
            subdued: readIndicatorsEnabled && isRead,
          }),
          isResolving && "opacity-70",
        )}
      >
        <div className="relative aspect-[1.08] w-full shrink-0 self-center overflow-hidden rounded-md border border-border/70 bg-muted/40">
          {showThumb && activeThumbSrc ? (
            <CachedImage
              src={activeThumbSrc}
              alt=""
              width={192}
              height={178}
              loading="lazy"
              className="absolute inset-0 size-full object-cover"
              onError={() => {
                setAttemptIdx((i) =>
                  i + 1 < thumbAttempts.length ? i + 1 : thumbAttempts.length,
                );
              }}
            />
          ) : thumbsExhausted ? (
            <span className="absolute inset-0 bg-muted/30" aria-hidden />
          ) : null}
          {showUnreadChrome ? (
            <span
              className="absolute right-2 top-2 size-2 rounded-full bg-primary ring-2 ring-background"
              aria-hidden
            />
          ) : null}
        </div>
        <div className="flex min-w-0 flex-col gap-1">
          <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
            {publication ? (
              <PublicationChip
                publication={{
                  name: publication.name,
                  faviconUrl: publication.faviconUrl,
                }}
                className="max-w-[12rem] border-0 bg-transparent px-0 py-0 text-foreground/80"
              />
            ) : null}
            {entry.wireItem?.source.domain?.trim() &&
            entry.wireItem.source.domain.trim() !== publication?.name ? (
              <>
                <span aria-hidden>•</span>
                <span className="truncate">{entry.wireItem.source.domain}</span>
              </>
            ) : null}
            {publication && showPublishedDate ? <span aria-hidden>•</span> : null}
            {showPublishedDate ? <span>{formattedDate}</span> : null}
            {entry.wireItem?.source.author?.trim() ? (
              <>
                <span aria-hidden>•</span>
                <span className="truncate">{entry.wireItem.source.author}</span>
              </>
            ) : null}
          </div>
          <p
            className={cn(
              "line-clamp-2 text-base font-semibold leading-snug text-foreground underline-offset-4 group-hover/entry-row:underline",
              showUnreadChrome && "font-bold",
              !displaySummary && "pr-8",
            )}
          >
            {displayTitle}
          </p>
          {displaySummary ? (
            <p className="line-clamp-2 pr-8 text-sm leading-5 text-muted-foreground">
              {displaySummary}
            </p>
          ) : null}
          {wireReasonLabels.length > 0 ? (
            <div className="flex flex-wrap gap-1.5 pt-0.5" aria-label="Why this story is on The Wire">
              {wireReasonLabels.map((label) => (
                <span
                  key={label}
                  className="rounded-full bg-primary/10 px-2 py-0.5 text-[11px] font-semibold text-[var(--purple-foreground)]"
                >
                  {label}
                </span>
              ))}
            </div>
          ) : null}
          {wireProvenance.length > 0 ? (
            <p className="line-clamp-1 pr-8 text-xs text-muted-foreground">
              {wireProvenance.join(" · ")}
            </p>
          ) : null}
          <div className="absolute bottom-2.5 right-2.5 flex items-center">
            <EntryCardActionMenu entry={entry} />
          </div>
        </div>
      </div>
    </div>
  );

  return (
    <ContextMenu>
      <ContextMenuTrigger className="flex w-full min-w-0 outline-none">
        {rowButton}
      </ContextMenuTrigger>
      <ContextMenuContent className="min-w-[11rem]">
        <EntryRowActions
          entry={entry}
          isRead={isRead}
          readIndicatorsEnabled={readIndicatorsEnabled}
          onMarkEntryRead={onMarkEntryRead}
          onMarkEntryUnread={onMarkEntryUnread}
          variant="context"
        />
      </ContextMenuContent>
    </ContextMenu>
  );
});
