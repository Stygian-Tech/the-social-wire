"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { useFolders } from "@/hooks/useFolders";
import { useSetPublicationFolder } from "@/hooks/usePublications";
import { rkeyFromURI } from "@/lib/pdsClient";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { RepoRecord, PublicationPrefsRecord } from "@/lib/pdsClient";

interface AssignFolderDialogProps {
  open: boolean;
  onClose: () => void;
  publication: DiscoveredPublication;
  currentPrefs?: RepoRecord<PublicationPrefsRecord>;
}

export function AssignFolderDialog({
  open,
  onClose,
  publication,
  currentPrefs,
}: AssignFolderDialogProps) {
  const { data: folders = [] } = useFolders();
  const setFolder = useSetPublicationFolder();
  const [selected, setSelected] = useState<string | null>(
    currentPrefs?.value.folderId ?? null
  );

  async function handleSave() {
    await setFolder.mutateAsync({
      publicationId: publication.publicationId,
      folderId: selected,
      existingRkey: currentPrefs ? rkeyFromURI(currentPrefs.uri) : undefined,
    });
    onClose();
  }

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Assign To Folder</DialogTitle>
        </DialogHeader>
        <div className="space-y-2">
          <Label>Folder</Label>
          <div className="flex flex-col gap-1">
            <button
              className={`rounded px-3 py-2 text-left text-sm hover:bg-muted ${
                selected === null ? "bg-muted font-medium" : ""
              }`}
              onClick={() => setSelected(null)}
            >
              All Publications (No Folder)
            </button>
            {folders.map((f) => (
              <button
                key={f.uri}
                className={`flex items-center gap-2 rounded px-3 py-2 text-left text-sm hover:bg-muted ${
                  selected === rkeyFromURI(f.uri) ? "bg-muted font-medium" : ""
                }`}
                onClick={() => setSelected(rkeyFromURI(f.uri))}
              >
                <span>{f.value.icon ?? "📁"}</span>
                <span>{f.value.name}</span>
              </button>
            ))}
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={handleSave} disabled={setFolder.isPending}>
            {setFolder.isPending ? "Saving…" : "Save"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
