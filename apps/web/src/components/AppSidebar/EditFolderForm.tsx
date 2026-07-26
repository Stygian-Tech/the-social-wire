"use client";

import { useId, useState } from "react";
import { FolderIconPicker } from "./FolderIconPicker";
import type { FolderBranchDisplay } from "./FolderBranch";
import { Button, buttonVariants } from "@/components/ui/button";
import {
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useUpdateFolder } from "@/hooks/useFolders";
import { cn } from "@/lib/utils";

export function EditFolderForm({
  folderUri,
  folder,
  onOpenChange,
}: {
  folderUri: string;
  folder: FolderBranchDisplay;
  onOpenChange: (open: boolean) => void;
}) {
  const nameId = useId();
  const iconId = useId();
  const iconLabelId = `${iconId}-label`;
  const [name, setName] = useState(folder.name);
  const [icon, setIcon] = useState(folder.icon ?? "folder");
  const [finishing, setFinishing] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const updateFolder = useUpdateFolder();
  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    if (!name.trim() || finishing) return;
    setSubmitError(null);
    setFinishing(true);
    try {
      await updateFolder.mutateAsync({
        uri: folderUri,
        updates: {
          name: name.trim(),
          icon: icon.trim() || "folder",
          iconImage: "",
        },
      });
      updateFolder.reset();
      onOpenChange(false);
    } catch (err) {
      console.error(err);
      setSubmitError(
        err instanceof Error ? err.message : "Something went wrong. Try again.",
      );
    } finally {
      setFinishing(false);
    }
  }
  const pending = finishing || updateFolder.isPending;
  return (
    <DialogContent>
      <DialogHeader>
        <DialogTitle>Edit Folder</DialogTitle>
        <DialogDescription>
          Change the folder name and choose the icon shown in the sidebar.
        </DialogDescription>
      </DialogHeader>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-1.5">
          <Label htmlFor={nameId}>Name</Label>
          <Input
            id={nameId}
            value={name}
            onChange={(event) => setName(event.target.value)}
            autoFocus
            required
          />
        </div>
        <div className="space-y-1.5">
          <Label id={iconLabelId}>Icon</Label>
          <FolderIconPicker
            labelledBy={iconLabelId}
            value={icon}
            onChange={setIcon}
          />
        </div>
        {submitError ? (
          <p className="text-sm text-destructive" role="alert">
            {submitError}
          </p>
        ) : null}
        <DialogFooter>
          <DialogClose render={<Button type="button" variant="outline" />}>
            Cancel
          </DialogClose>
          <button
            type="submit"
            disabled={!name.trim() || pending}
            className={cn(buttonVariants())}
          >
            {pending ? "Saving..." : "Save Changes"}
          </button>
        </DialogFooter>
      </form>
    </DialogContent>
  );
}
