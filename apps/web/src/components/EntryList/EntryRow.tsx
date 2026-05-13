"use client";

import type { EntryListItem } from "@/lib/atprotoClient";

interface EntryRowProps {
  entry: EntryListItem;
  isSelected: boolean;
  onSelect: (entryId: string) => void;
}

export function EntryRow({ entry, isSelected, onSelect }: EntryRowProps) {
  const date = new Date(entry.publishedAt);
  const formattedDate = date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: date.getFullYear() !== new Date().getFullYear() ? "numeric" : undefined,
  });

  return (
    <button
      onClick={() => onSelect(entry.entryId)}
      className={`w-full border-b px-4 py-3 text-left transition-colors hover:bg-muted/50 ${
        isSelected ? "bg-muted" : ""
      }`}
    >
      <p className="truncate text-sm font-medium leading-snug">{entry.title}</p>
      {entry.summary && (
        <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground leading-relaxed">
          {entry.summary}
        </p>
      )}
      <p className="mt-1 text-xs text-muted-foreground">{formattedDate}</p>
    </button>
  );
}
