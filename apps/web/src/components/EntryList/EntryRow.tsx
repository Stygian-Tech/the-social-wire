"use client";

import { useMemo, useState } from "react";
import { BookmarkPlus, Check, MoreHorizontal } from "lucide-react";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Button } from "@/components/ui/button";
import { thumbnailImageSrcAttempts } from "@/lib/publicResourceUrl";
import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";
import { cn } from "@/lib/utils";
import type { EntryListItem } from "@/lib/atprotoClient";
import { CachedImage } from "@/components/shared/CachedImage";
import {
  useEntryIsLatrSaved,
  useSaveReadLaterEntryMutation,
} from "@/hooks/useLatrSaved";
import { useConfiguredReadLaterService } from "@/hooks/useReadLaterPreferences";

interface EntryRowProps {
  entry: EntryListItem;
  isSelected: boolean;
  onSelect: (entryId: string) => void;
  isRead: boolean;
  readIndicatorsEnabled: boolean;
  onMarkEntryRead: (entryId: string) => void;
  onMarkEntryUnread: (entryId: string) => void;
}

function EntryRowActions({
  entry,
  isRead,
  readIndicatorsEnabled,
  onMarkEntryRead,
  onMarkEntryUnread,
  variant,
}: {
  entry: EntryListItem;
  isRead: boolean;
  readIndicatorsEnabled: boolean;
  onMarkEntryRead: (entryId: string) => void;
  onMarkEntryUnread: (entryId: string) => void;
  variant: "context" | "dropdown";
}) {
  const saveLaterMut = useSaveReadLaterEntryMutation();
  const { serviceId: configuredReadLaterId } = useConfiguredReadLaterService();
  const latrReadLaterWritesEnabled = configuredReadLaterId === "latr-link";
  const alreadySaved = useEntryIsLatrSaved(entry.entryId);
  const Item = variant === "context" ? ContextMenuItem : DropdownMenuItem;

  const saveDisabled =
    !latrReadLaterWritesEnabled || alreadySaved || saveLaterMut.isPending;

  return (
    <>
      <Item
        className="gap-2"
        disabled={saveDisabled}
        onClick={() => {
          saveLaterMut.mutate({
            entryId: entry.entryId,
            title: entry.title,
            excerpt: entry.summary,
          });
        }}
      >
        {alreadySaved ? (
          <Check className="size-4 text-emerald-600" />
        ) : (
          <BookmarkPlus className="size-4" />
        )}
        {alreadySaved ? "Saved" : "Save"}
      </Item>
      {readIndicatorsEnabled ? (
        !isRead ? (
          <Item
            className="gap-2"
            onClick={() => onMarkEntryRead(entry.entryId)}
          >
            Mark As Read
          </Item>
        ) : (
          <Item
            className="gap-2"
            onClick={() => onMarkEntryUnread(entry.entryId)}
          >
            Mark As Unread
          </Item>
        )
      ) : null}
    </>
  );
}

export function EntryRow({
  entry,
  isSelected,
  onSelect,
  isRead,
  readIndicatorsEnabled,
  onMarkEntryRead,
  onMarkEntryUnread,
}: EntryRowProps) {
  const date = new Date(entry.publishedAt);
  const formattedDate = date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: date.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined,
  });

  const showUnreadChrome = readIndicatorsEnabled && !isRead;
  const thumbAttempts = useMemo(
    () =>
      thumbnailImageSrcAttempts(entry.thumbnailUrl, entry.thumbnailFallbackUrl),
    [entry.thumbnailUrl, entry.thumbnailFallbackUrl]
  );
  const displayTitle = useMemo(
    () => decodeHtmlEntities(entry.title),
    [entry.title]
  );
  const displaySummary = useMemo(
    () => (entry.summary ? decodeHtmlEntities(entry.summary) : undefined),
    [entry.summary]
  );
  const [attemptIdx, setAttemptIdx] = useState(0);

  const activeThumbSrc =
    thumbAttempts.length > 0 && attemptIdx < thumbAttempts.length
      ? thumbAttempts[attemptIdx]
      : undefined;
  const thumbsExhausted =
    thumbAttempts.length > 0 && attemptIdx >= thumbAttempts.length;
  const showThumb = Boolean(activeThumbSrc) && !thumbsExhausted;

  const rowButton = (
    <div className="group/entry-row relative flex w-full items-stretch">
      <button
        type="button"
        onClick={() => onSelect(entry.entryId)}
        className={cn(
          "min-w-0 flex-1 border-b px-4 py-3 text-left transition-colors hover:bg-muted/50",
          isSelected && "bg-muted",
          readIndicatorsEnabled && isRead && "opacity-80"
        )}
      >
        <span className="flex items-start gap-3">
          {showUnreadChrome ? (
            <span
              className="mt-2 size-1.5 shrink-0 rounded-full bg-primary"
              aria-hidden
            />
          ) : (
            <span className="mt-2 size-1.5 shrink-0 rounded-full" aria-hidden />
          )}
          <span
            className={cn(
              "relative mt-0.5 h-12 w-12 shrink-0 overflow-hidden rounded-md border border-border/50 bg-muted/35",
              showThumb ? "bg-muted" : thumbsExhausted ? "opacity-60" : null
            )}
          >
            {activeThumbSrc ? (
              <CachedImage
                src={activeThumbSrc}
                alt=""
                width={48}
                height={48}
                loading="lazy"
                className="absolute inset-0 h-full w-full object-cover"
                onError={() => {
                  setAttemptIdx((i) =>
                    i + 1 < thumbAttempts.length ? i + 1 : thumbAttempts.length
                  );
                }}
              />
            ) : thumbsExhausted ? (
              <span
                className="block h-full w-full bg-muted/30"
                aria-hidden
              />
            ) : null}
          </span>
          <span className="min-w-0 flex-1 pr-8">
            <p
              className={cn(
                "min-w-0 break-words text-pretty text-sm leading-snug",
                showUnreadChrome ? "font-semibold" : "font-medium"
              )}
            >
              {displayTitle}
            </p>
            {displaySummary && (
              <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground leading-relaxed">
                {displaySummary}
              </p>
            )}
            <p className="mt-1 text-xs text-muted-foreground">{formattedDate}</p>
          </span>
        </span>
      </button>
      <div className="absolute right-2 top-1/2 z-10 -translate-y-1/2">
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                className="size-8 opacity-100 md:opacity-0 md:group-hover/entry-row:opacity-100"
                aria-label="Article Actions"
                onClick={(event) => event.stopPropagation()}
              />
            }
          >
            <MoreHorizontal className="size-4" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="min-w-[11rem]">
            <EntryRowActions
              entry={entry}
              isRead={isRead}
              readIndicatorsEnabled={readIndicatorsEnabled}
              onMarkEntryRead={onMarkEntryRead}
              onMarkEntryUnread={onMarkEntryUnread}
              variant="dropdown"
            />
          </DropdownMenuContent>
        </DropdownMenu>
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
}
