"use client";

import { EditFolderForm } from "./EditFolderForm";
import type { FolderBranchDisplay } from "./FolderBranch";
import { Dialog } from "@/components/ui/dialog";

export function EditFolderDialog({
  open,
  onOpenChange,
  folderUri,
  folder,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  folderUri: string;
  folder: FolderBranchDisplay;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      {open ? (
        <EditFolderForm
          folderUri={folderUri}
          folder={folder}
          onOpenChange={onOpenChange}
        />
      ) : null}
    </Dialog>
  );
}
