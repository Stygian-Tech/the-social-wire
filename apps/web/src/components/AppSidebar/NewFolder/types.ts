import type { ReactNode } from "react";

export type CreateFolderCreatedPayload = { uri: string };

export interface CreateFolderFormFieldsProps {
  onCloseRequest: () => void;
  onCreated?: (payload: CreateFolderCreatedPayload) => void | Promise<void>;
  submitLabel?: string;
  pendingSubmitLabel?: string;
}

export interface ControlledCreateFolderDialogProps
  extends Omit<CreateFolderFormFieldsProps, "onCloseRequest"> {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  description?: ReactNode;
  dialogTitle?: string;
}
