"use client";

import { BookmarkPlus, Check } from "lucide-react";
import { ContextMenuItem } from "@/components/ui/context-menu";
import { DropdownMenuItem } from "@/components/ui/dropdown-menu";
import {
  useEntryIsLatrSaved,
  useSaveReadLaterEntryMutation,
} from "@/hooks/useLatrSaved";
import type { EntryListItem } from "@/lib/atprotoClient";

export function EntryRowActions({
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
  const alreadySaved = useEntryIsLatrSaved(entry.entryId);
  const Item = variant === "context" ? ContextMenuItem : DropdownMenuItem;
  return (
    <>
      <Item
        className="gap-2"
        disabled={alreadySaved}
        onClick={() =>
          saveLaterMut.mutate({
            entryId: entry.entryId,
            url: entry.originalUrl,
            title: entry.title,
            excerpt: entry.summary,
          })
        }
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
