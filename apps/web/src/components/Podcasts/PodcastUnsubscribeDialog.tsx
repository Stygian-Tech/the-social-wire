"use client";

import { useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import type { PodcastShow } from "@/lib/podcasts/client";

export function PodcastUnsubscribeDialog({ show, onClose, onConfirm }: {
  show: PodcastShow | null;
  onClose: () => void;
  onConfirm: (show: PodcastShow) => Promise<void>;
}) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const confirming = useRef(false);
  async function confirm() {
    if (!show || confirming.current) return;
    confirming.current = true;
    setPending(true);
    setError(null);
    try {
      await onConfirm(show);
      onClose();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could Not Unsubscribe. Please Retry.");
    } finally {
      confirming.current = false;
      setPending(false);
    }
  }
  return <Dialog open={show !== null} onOpenChange={(open) => { if (!open && !pending) onClose(); }}>
    <DialogContent showCloseButton={!pending}>
      <DialogHeader>
        <DialogTitle>Unsubscribe?</DialogTitle>
        <DialogDescription>Unsubscribe from {show?.title}? This show will be removed from your subscriptions.</DialogDescription>
      </DialogHeader>
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
      <DialogFooter>
        <DialogClose render={<Button variant="outline" disabled={pending} />}>Cancel</DialogClose>
        <Button variant="destructive" disabled={pending} onClick={() => void confirm()}>{pending ? "Unsubscribing…" : "Unsubscribe"}</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>;
}
