"use client";

import { useState } from "react";
import { Dialog, DialogClose, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";
import type { PodcastShow } from "@/lib/podcasts/client";

export function PodcastShowDescription({ show }: { show: PodcastShow }) {
  const [open, setOpen] = useState(false);
  const paragraphs = (show.description ?? "")
    .replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?\s*>/gi, "\n")
    .replace(/<\/(?:p|div|li|h[1-6])\s*>/gi, "\n\n");
  let description: string;
  try { description = decodeHtmlEntities(paragraphs); }
  catch { description = paragraphs.replace(/<[^>]*>/g, "").trim(); }
  if (!description) return null;
  return <Dialog open={open} onOpenChange={setOpen}>
    <div className="space-y-1">
      <p className="line-clamp-3 whitespace-pre-wrap text-sm text-muted-foreground">{description}</p>
      <DialogTrigger className="min-h-8 rounded px-1 text-xs font-medium underline underline-offset-4 hover:bg-accent pointer-coarse:min-h-11">Show More</DialogTrigger>
    </div>
    <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-xl" showCloseButton={false}>
      <DialogHeader><DialogTitle>About {show.title}</DialogTitle></DialogHeader>
      <div className="min-h-0 overflow-y-auto overscroll-contain whitespace-pre-wrap break-words pr-1 text-sm" tabIndex={0} aria-label="Full Podcast Description">{description}</div>
      <DialogFooter><DialogClose className="min-h-9 rounded border px-3 text-sm hover:bg-accent pointer-coarse:min-h-11">Close</DialogClose></DialogFooter>
    </DialogContent>
  </Dialog>;
}
