"use client";

import { type ReactNode, useCallback, useId, useState } from "react";
import { Button, buttonVariants } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useCreateFolder } from "@/hooks/useFolders";
import { Plus } from "lucide-react";
import { cn } from "@/lib/utils";

export type CreateFolderCreatedPayload = { uri: string };

interface CreateFolderFormFieldsProps {
  onOpenChange: (open: boolean) => void;
  onCreated?: (payload: CreateFolderCreatedPayload) => void | Promise<void>;
  description?: ReactNode;
  dialogTitle?: string;
  submitLabel?: string;
  pendingSubmitLabel?: string;
}

function CreateFolderFormFields({
  onOpenChange,
  onCreated,
  description,
  dialogTitle = "New Folder",
  submitLabel = "Create",
  pendingSubmitLabel = "Creating…",
}: CreateFolderFormFieldsProps) {
  const labelId = useId();
  const descId = `${labelId}-desc`;
  const nameId = `${labelId}-name`;
  const iconId = `${labelId}-icon`;
  const [name, setName] = useState("");
  const [icon, setIcon] = useState("");
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
        icon: icon.trim() || undefined,
      });
      if (onCreated) await Promise.resolve(onCreated(result));
      onOpenChange(false);
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
    <DialogContent aria-describedby={description ? descId : undefined}>
      <DialogHeader>
        <DialogTitle>{dialogTitle}</DialogTitle>
        {description ? (
          <DialogDescription id={descId}>{description}</DialogDescription>
        ) : null}
      </DialogHeader>
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
          <Label htmlFor={iconId}>Icon (Optional)</Label>
          <Input
            id={iconId}
            value={icon}
            onChange={(e) => setIcon(e.target.value)}
            placeholder="e.g. 💻"
            maxLength={4}
          />
          <p className="text-xs text-muted-foreground">
            Enter an emoji. Leave blank to use the default folder icon.
          </p>
        </div>
        {submitError ? (
          <p className="text-sm text-destructive" role="alert">
            {submitError}
          </p>
        ) : null}
        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={pending}
          >
            Cancel
          </Button>
          {/* Base UI `Button` merges internal props second and forces type="button", so type="submit" is ignored — use a native submit control */}
          <button
            type="submit"
            disabled={!name.trim() || pending}
            className={cn(buttonVariants())}
          >
            {pending ? pendingSubmitLabel : submitLabel}
          </button>
        </DialogFooter>
      </form>
    </DialogContent>
  );
}

export interface ControlledCreateFolderDialogProps
  extends CreateFolderFormFieldsProps {
  open: boolean;
}

export function ControlledCreateFolderDialog({
  open,
  onOpenChange,
  ...fields
}: ControlledCreateFolderDialogProps) {
  const [formKey, setFormKey] = useState(0);

  const handleOpenChange = useCallback(
    (next: boolean) => {
      onOpenChange(next);
      if (!next) setFormKey((k) => k + 1);
    },
    [onOpenChange]
  );

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <CreateFolderFormFields key={formKey} onOpenChange={handleOpenChange} {...fields} />
    </Dialog>
  );
}

export function NewFolderDialog() {
  const [open, setOpen] = useState(false);
  const [formKey, setFormKey] = useState(0);

  const handleOpenChange = useCallback((next: boolean) => {
    setOpen(next);
    if (!next) setFormKey((k) => k + 1);
  }, []);

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger
        render={
          <Button variant="ghost" size="sm" className="w-full justify-start gap-2" />
        }
      >
        <Plus className="h-4 w-4" />
        New Folder
      </DialogTrigger>
      <CreateFolderFormFields key={formKey} onOpenChange={handleOpenChange} />
    </Dialog>
  );
}
