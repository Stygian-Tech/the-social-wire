"use client";

import { useId, useState } from "react";
import { Button, buttonVariants } from "@/components/ui/button";
import {
  DialogClose,
  DialogFooter,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useCreateFolder } from "@/hooks/useFolders";
import { cn } from "@/lib/utils";
import { FolderIconPicker } from "../FolderIconPicker";
import type { CreateFolderFormFieldsProps } from "./types";

export function CreateFolderFormFields({
  onCloseRequest,
  onCreated,
  submitLabel = "Create",
  pendingSubmitLabel = "Creating…",
}: CreateFolderFormFieldsProps) {
  const nameId = useId();
  const iconId = useId();
  const iconLabelId = `${iconId}-label`;
  const [name, setName] = useState("");
  const [icon, setIcon] = useState("folder");
  const [finishing, setFinishing] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const createFolder = useCreateFolder();

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim() || finishing) return;
    setSubmitError(null);
    setFinishing(true);
    try {
      const result = await createFolder.mutateAsync({
        name: name.trim(),
        icon: icon.trim() || "folder",
      });
      try {
        if (onCreated) await Promise.resolve(onCreated(result));
      } finally {
        createFolder.reset();
        onCloseRequest();
      }
    } catch (err) {
      console.error(err);
      setSubmitError(
        err instanceof Error ? err.message : "Something went wrong. Try again."
      );
    } finally {
      setFinishing(false);
    }
  }

  const pending = finishing || createFolder.isPending;

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="space-y-1.5">
        <Label htmlFor={nameId}>Name</Label>
        <Input
          id={nameId}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Tech"
          autoFocus
          required
        />
      </div>
      <div className="space-y-1.5">
        <Label id={iconLabelId}>Icon or Emoji</Label>
        <FolderIconPicker
          labelledBy={iconLabelId}
          value={icon}
          disabled={pending}
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
          {pending ? pendingSubmitLabel : submitLabel}
        </button>
      </DialogFooter>
    </form>
  );
}
