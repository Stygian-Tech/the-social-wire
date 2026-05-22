"use client";

import { useMemo, useState } from "react";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import { thumbnailImageSrcAttempts } from "@/lib/publicResourceUrl";
import { cn } from "@/lib/utils";
import type { EntryListItem } from "@/lib/atprotoClient";
import { CachedImage } from "@/components/shared/CachedImage";

interface EntryRowProps {
  entry: EntryListItem;
  isSelected: boolean;
  onSelect: (entryId: string) => void;
  isRead: boolean;
  readIndicatorsEnabled: boolean;
  onMarkEntryRead: (entryId: string) => void;
  onMarkEntryUnread: (entryId: string) => void;
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
  const [attemptIdx, setAttemptIdx] = useState(0);

  const activeThumbSrc =
    thumbAttempts.length > 0 && attemptIdx < thumbAttempts.length
      ? thumbAttempts[attemptIdx]
      : undefined;
  const thumbsExhausted =
    thumbAttempts.length > 0 && attemptIdx >= thumbAttempts.length;
  const showThumb = Boolean(activeThumbSrc) && !thumbsExhausted;

  const rowButton = (
    <button
      type="button"
      onClick={() => onSelect(entry.entryId)}
      className={cn(
        "w-full border-b px-4 py-3 text-left transition-colors hover:bg-muted/50",
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
        <span className="min-w-0 flex-1">
          <p
            className={cn(
              "min-w-0 break-words text-pretty text-sm leading-snug",
              showUnreadChrome ? "font-semibold" : "font-medium"
            )}
          >
            {entry.title}
          </p>
          {entry.summary && (
            <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground leading-relaxed">
              {entry.summary}
            </p>
          )}
          <p className="mt-1 text-xs text-muted-foreground">{formattedDate}</p>
        </span>
      </span>
    </button>
  );

  if (!readIndicatorsEnabled) {
    return rowButton;
  }

  return (
    <ContextMenu>
      <ContextMenuTrigger className="flex w-full min-w-0 outline-none">
        {rowButton}
      </ContextMenuTrigger>
      <ContextMenuContent className="min-w-[11rem]">
        {!isRead ? (
          <ContextMenuItem
            className="gap-2"
            onClick={() => onMarkEntryRead(entry.entryId)}
          >
            Mark As Read
          </ContextMenuItem>
        ) : (
          <ContextMenuItem
            className="gap-2"
            onClick={() => onMarkEntryUnread(entry.entryId)}
          >
            Mark As Unread
          </ContextMenuItem>
        )}
      </ContextMenuContent>
    </ContextMenu>
  );
}
