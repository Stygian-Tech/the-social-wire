"use client";

import { useState } from "react";
import { cn } from "@/lib/utils";
import type { EntryListItem } from "@/lib/atprotoClient";

interface EntryRowProps {
  entry: EntryListItem;
  isSelected: boolean;
  onSelect: (entryId: string) => void;
  isRead: boolean;
  readIndicatorsEnabled: boolean;
}

export function EntryRow({
  entry,
  isSelected,
  onSelect,
  isRead,
  readIndicatorsEnabled,
}: EntryRowProps) {
  const date = new Date(entry.publishedAt);
  const formattedDate = date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: date.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined,
  });

  const showUnreadChrome = readIndicatorsEnabled && !isRead;
  const [thumbFailed, setThumbFailed] = useState(false);
  const showThumb = Boolean(entry.thumbnailUrl) && !thumbFailed;

  return (
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
            showThumb && "bg-muted"
          )}
        >
          {entry.thumbnailUrl ? (
            /* eslint-disable-next-line @next/next/no-img-element -- PDS / arbitrary publisher URLs */
            <img
              src={entry.thumbnailUrl}
              alt=""
              width={48}
              height={48}
              loading="lazy"
              decoding="async"
              onError={() => setThumbFailed(true)}
              className={cn(
                "absolute inset-0 h-full w-full object-cover",
                thumbFailed && "hidden"
              )}
            />
          ) : null}
        </span>
        <span className="min-w-0 flex-1">
          <p
            className={cn(
              "truncate text-sm leading-snug",
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
}
