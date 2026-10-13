"use client";

import { useMemo, useState } from "react";
import { MoreHorizontal } from "lucide-react";

import { ArticleSocialToolbar } from "@/components/EntryDetail/ArticleSocialToolbar";
import type { EntryDetail, EntryListItem } from "@/lib/atprotoClient";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";

export function LazyArticleCardActions({ entry, showWireFeedback }: { entry: EntryListItem; showWireFeedback: boolean }) {
  const [activated, setActivated] = useState(false);
  const [open, setOpen] = useState(false);
  const actionEntry = useMemo<EntryDetail>(
    () => ({
      entryId: entry.entryId,
      financeItem: entry.financeItem,
      title: entry.title,
      summary: entry.summary,
      publishedAt: entry.publishedAt,
      contentHtml: entry.summary ?? "",
      thumbnailUrl: entry.thumbnailUrl,
      thumbnailFallbackUrl: entry.thumbnailFallbackUrl,
      originalUrl: entry.originalUrl,
      embedUrl: entry.originalUrl,
      ...(entry.wireItem?.representativeUri
        ? { entryId: entry.wireItem.representativeUri }
        : {}),
    }),
    [entry],
  );

  return (
    <div
      className="flex items-center"
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => event.stopPropagation()}
    >
      <DropdownMenu open={open} onOpenChange={next => { if (next) setActivated(true); setOpen(next); }}>
        <DropdownMenuTrigger render={<Button type="button" variant="ghost" size="icon-sm" className="size-8 shrink-0" aria-label="Article Actions" />}>
          <MoreHorizontal className="size-4" />
        </DropdownMenuTrigger>
        {activated ? <ArticleSocialToolbar entry={actionEntry} variant="menu" menuContentOnly showWireFeedback={showWireFeedback} /> : null}
      </DropdownMenu>
    </div>
  );
}
