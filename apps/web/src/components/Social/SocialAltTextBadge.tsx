"use client";

import { useState } from "react";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";

export function SocialAltTextBadge({ alt, label = "View Alt Text" }: { alt: string; label?: string }) {
  const [open, setOpen] = useState(false);
  if (!alt.trim()) return null;
  return <Dialog open={open} onOpenChange={setOpen}>
    <button type="button" aria-label={label} className="absolute right-2 top-2 z-10 rounded-md bg-black/75 px-2 py-1 text-xs font-semibold text-white shadow-sm hover:bg-black/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
      onClick={event => { event.stopPropagation(); setOpen(true); }}>ALT</button>
    <DialogContent className="sm:max-w-lg">
      <DialogTitle>Alt Text</DialogTitle>
      <DialogDescription className="sr-only">Description provided by the author.</DialogDescription>
      <p className="max-h-[65dvh] overflow-y-auto whitespace-pre-wrap break-words text-sm [overflow-wrap:anywhere]">{alt}</p>
    </DialogContent>
  </Dialog>;
}
