"use client";

import { Archive, ArchiveRestore, ExternalLink, Tags, Trash2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import type { MergedLatrSave } from "@/lib/pdsClient";

export function SavedLinkCardActions({
  row,
  isArchivedView,
  disabled,
  onOpen,
  onEditTags,
  onArchive,
  onUnarchive,
  onDelete,
}: {
  row: MergedLatrSave;
  isArchivedView: boolean;
  disabled: boolean;
  onOpen: (row: MergedLatrSave) => void;
  onEditTags: (row: MergedLatrSave) => void;
  onArchive: (row: MergedLatrSave) => void;
  onUnarchive: (row: MergedLatrSave) => void;
  onDelete: (row: MergedLatrSave) => void;
}) {
  const title = row.title?.trim() || row.site?.trim() || "Saved Article";

  return (
    <div
      className="flex items-center gap-0.5"
      role="toolbar"
      aria-label={`Actions for ${title}`}
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => event.stopPropagation()}
    >
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="size-8"
        disabled={disabled}
        aria-label={`Edit Tags for ${title}`}
        title="Edit Tags"
        onClick={() => onEditTags(row)}
      >
        <Tags className="size-4" />
      </Button>
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="size-8"
        aria-label={`Open ${title}`}
        title="Open"
        onClick={() => onOpen(row)}
      >
        <ExternalLink className="size-4" />
      </Button>
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="size-8"
        disabled={disabled}
        aria-label={`${isArchivedView ? "Unarchive" : "Archive"} ${title}`}
        title={isArchivedView ? "Unarchive" : "Archive"}
        onClick={() =>
          isArchivedView ? onUnarchive(row) : onArchive(row)
        }
      >
        {isArchivedView ? (
          <ArchiveRestore className="size-4" />
        ) : (
          <Archive className="size-4" />
        )}
      </Button>
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="size-8 text-destructive hover:bg-destructive/10 hover:text-destructive"
        disabled={disabled}
        aria-label={`Remove ${title} From Library`}
        title="Remove"
        onClick={() => onDelete(row)}
      >
        <Trash2 className="size-4" />
      </Button>
    </div>
  );
}
