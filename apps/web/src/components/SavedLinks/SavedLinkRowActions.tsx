import { Archive, ArchiveRestore, Trash2 } from "lucide-react";
import {
  ContextMenuItem,
  ContextMenuSeparator,
} from "@/components/ui/context-menu";
import type { MergedLatrSave } from "@/lib/pdsClient";

export function SavedLinkRowActions({
  row,
  isArchivedView,
  onArchive,
  onUnarchive,
  onDelete,
}: {
  row: MergedLatrSave;
  isArchivedView: boolean;
  onArchive: (row: MergedLatrSave) => void;
  onUnarchive: (row: MergedLatrSave) => void;
  onDelete: (row: MergedLatrSave) => void;
}) {
  return (
    <>
      {isArchivedView ? (
        <ContextMenuItem className="gap-2" onClick={() => onUnarchive(row)}>
          <ArchiveRestore className="size-4" />
          Unarchive
        </ContextMenuItem>
      ) : (
        <ContextMenuItem className="gap-2" onClick={() => onArchive(row)}>
          <Archive className="size-4" />
          Archive
        </ContextMenuItem>
      )}
      <ContextMenuSeparator />
      <ContextMenuItem
        variant="destructive"
        className="gap-2"
        onClick={() => onDelete(row)}
      >
        <Trash2 className="size-4" />
        Delete
      </ContextMenuItem>
    </>
  );
}
