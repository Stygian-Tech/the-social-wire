"use client";

import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";

export function SportsPublicInterestDialog({ open, onAccept, onCancel }: {
  open: boolean;
  onAccept: () => void;
  onCancel: () => void;
}) {
  return <Dialog open={open} onOpenChange={value => { if (!value) onCancel(); }}>
    <DialogContent showCloseButton={false}>
      <DialogHeader>
        <DialogTitle>Your Sports Interests Are Public</DialogTitle>
        <DialogDescription>Follows and mutes are public records on your PDS. Others may copy them. Removal deletes your PDS record and our derived preferences; downstream copies may remain.</DialogDescription>
      </DialogHeader>
      <p className="text-sm text-muted-foreground">We’ll remember your acknowledgement for this account in this browser.</p>
      <DialogFooter>
        <DialogClose render={<Button variant="outline" />}>Cancel</DialogClose>
        <Button onClick={onAccept}>I Understand</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>;
}
