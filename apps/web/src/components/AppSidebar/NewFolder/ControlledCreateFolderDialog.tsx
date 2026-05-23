"use client";

import { useCallback, useId, useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { CreateFolderFormFields } from "./CreateFolderFormFields";
import type { ControlledCreateFolderDialogProps } from "./types";

export function ControlledCreateFolderDialog({
  open,
  onOpenChange,
  dialogTitle = "New Folder",
  description,
  ...fields
}: ControlledCreateFolderDialogProps) {
  const [formKey, setFormKey] = useState(0);
  const descriptionId = useId();

  const handleOpenChange = useCallback(
    (next: boolean) => {
      onOpenChange(next);
      if (next) setFormKey((k) => k + 1);
    },
    [onOpenChange]
  );

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent aria-describedby={description ? descriptionId : undefined}>
        <DialogHeader>
          <DialogTitle>{dialogTitle}</DialogTitle>
          {description ? (
            <DialogDescription id={descriptionId}>{description}</DialogDescription>
          ) : null}
        </DialogHeader>
        <CreateFolderFormFields
          key={formKey}
          {...fields}
          onCloseRequest={() => handleOpenChange(false)}
        />
      </DialogContent>
    </Dialog>
  );
}
