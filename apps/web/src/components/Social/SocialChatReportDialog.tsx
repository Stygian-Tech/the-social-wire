"use client";

import { useState } from "react";
import { ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle } from "@/components/ui/dialog";

const reasons = [
  ["com.atproto.moderation.defs#reasonSpam", "Spam"],
  ["com.atproto.moderation.defs#reasonViolation", "Harassment or Rule Violation"],
  ["com.atproto.moderation.defs#reasonMisleading", "Misleading Content"],
  ["com.atproto.moderation.defs#reasonSexual", "Unwanted Sexual Content"],
  ["com.atproto.moderation.defs#reasonOther", "Other"],
] as const;

export function SocialChatReportDialog({ pending, error, onClose, onSubmit }: { pending: boolean; error?: string; onClose: () => void; onSubmit: (reasonType: string, reason: string) => void }) {
  // The parent mounts a fresh dialog for each report target.
  const [reasonType, setReasonType] = useState<string>(reasons[0][0]);
  const [reason, setReason] = useState("");
  return <Dialog open onOpenChange={open => { if (!open && !pending) onClose(); }}>
    <DialogContent showCloseButton={!pending}>
      <DialogTitle>Report Chat</DialogTitle>
      <DialogDescription>Send this report to Bluesky Moderation. Include details that help reviewers understand what happened.</DialogDescription>
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
      <label htmlFor="chat-report-reason" className="text-sm font-medium">Reason</label>
      <div className="relative min-w-0"><select id="chat-report-reason" disabled={pending} value={reasonType} onChange={event => setReasonType(event.target.value)} className="w-full appearance-none rounded-md border bg-background py-2 pl-3 pr-9 text-sm">{reasons.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select><ChevronDown aria-hidden className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2" /></div>
      <label htmlFor="chat-report-details" className="text-sm font-medium">Additional Details</label>
      <textarea id="chat-report-details" disabled={pending} maxLength={2000} rows={4} value={reason} onChange={event => setReason(event.target.value)} className="w-full resize-y rounded-md border bg-background p-3 text-sm" />
      <DialogFooter><DialogClose disabled={pending} render={<Button variant="outline" />}>Cancel</DialogClose><Button disabled={pending} onClick={() => onSubmit(reasonType, reason)}>{pending ? "Sending…" : "Send Report"}</Button></DialogFooter>
    </DialogContent>
  </Dialog>;
}
