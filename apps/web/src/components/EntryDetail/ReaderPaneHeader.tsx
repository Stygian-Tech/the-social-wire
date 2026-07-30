"use client";

import { ChevronLeft } from "lucide-react";
import { ArticleSocialToolbar } from "@/components/EntryDetail/ArticleSocialToolbar";
import { Button } from "@/components/ui/button";
import type { EntryDetail } from "@/lib/atprotoClient";

interface ReaderPaneHeaderProps {
  entry: EntryDetail | null | undefined;
  fallbackTitle: string;
  onBack: () => void;
}

export function ReaderPaneHeader({
  entry,
  fallbackTitle,
  onBack,
}: ReaderPaneHeaderProps) {
  const title = entry?.title?.trim() || fallbackTitle;

  return (
    <div className="sticky top-0 z-30 flex min-h-[52px] shrink-0 items-center gap-2 border-b bg-background/90 px-1.5 py-1 backdrop-blur-md md:px-3">
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="size-11 shrink-0 md:hidden"
        aria-label="Back to Articles"
        onClick={onBack}
      >
        <ChevronLeft className="size-5" />
      </Button>
      <span
        className="min-w-0 flex-1 truncate text-sm font-semibold text-foreground"
        title={title}
      >
        {title}
      </span>
      <ArticleSocialToolbar entry={entry ?? null} variant="menu" />
    </div>
  );
}
