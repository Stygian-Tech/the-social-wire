"use client";

import { useMemo } from "react";
import { ExternalLink } from "lucide-react";
import { EntryArticleEmbed } from "@/components/EntryDetail/EntryArticleEmbed";
import { EntrySocialToolbar } from "@/components/EntryDetail/EntrySocialToolbar";
import { Skeleton } from "@/components/ui/skeleton";
import { useEntry } from "@/hooks/useEntries";
import { sanitizeHTMLWithLinks } from "@/lib/sanitize";

interface EntryDetailProps {
  entryId: string;
}

export function EntryDetail({ entryId }: EntryDetailProps) {
  const { data: entry, isLoading, error } = useEntry(entryId);

  const safeHTML = useMemo(
    () => sanitizeHTMLWithLinks(entry?.contentHtml ?? ""),
    [entryId, entry?.contentHtml]
  );

  /**
   * Prefer sanitized record HTML over live iframe when present — avoids broken embeds (e.g. fed
   * bridge query params) and mixed-origin iframe 404s; tradeoff: no live-site chrome in-page.
   */
  const preferRecordBodyOverEmbed = Boolean(entry) && safeHTML.trim().length > 0;

  if (isLoading) {
    return (
      <div className="space-y-4 p-4 sm:p-6">
        <Skeleton className="h-8 w-3/4" />
        <Skeleton className="h-4 w-1/4" />
        <div className="space-y-2 pt-3">
          {Array.from({ length: 8 }).map((_, i) => (
            <Skeleton key={i} className="h-4 w-full" />
          ))}
        </div>
      </div>
    );
  }

  if (error || !entry) {
    return (
      <div className="flex h-full items-center justify-center px-4 py-8 text-sm text-muted-foreground">
        Failed to load entry.
      </div>
    );
  }

  const date = new Date(entry.publishedAt).toLocaleDateString(undefined, {
    year: "numeric",
    month: "long",
    day: "numeric",
  });

  const showEmbed = Boolean(entry.embedUrl) && !preferRecordBodyOverEmbed;

  return (
    <article className="w-full max-w-none px-3 pb-8 pt-1 sm:px-4 sm:pb-10 sm:pt-2 md:px-6 lg:px-8">
      <header className="mb-3 sm:mb-4">
        <h1 className="text-xl font-bold leading-tight sm:text-2xl">{entry.title}</h1>
        <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground sm:text-sm">
          <time dateTime={entry.publishedAt}>{date}</time>
          {(entry.embedUrl ?? entry.originalUrl) && !showEmbed && (
            <a
              href={entry.embedUrl ?? entry.originalUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex min-h-[44px] min-w-0 items-center gap-1 py-2 hover:text-foreground transition-colors sm:min-h-0 sm:py-0"
            >
              <ExternalLink className="h-3.5 w-3.5 shrink-0" />
              View original
            </a>
          )}
        </div>
      </header>

      <EntrySocialToolbar entry={entry} />

      {showEmbed ? (
        <EntryArticleEmbed
          url={entry.embedUrl!}
          title={entry.title}
          className="mb-5 sm:mb-6"
        />
      ) : null}

      {!showEmbed && !safeHTML.trim() ? (
        <p className="text-sm text-muted-foreground">
          No embed URL or HTML body is available for this entry.
        </p>
      ) : (
        <div
          className="prose prose-sm dark:prose-invert max-w-none"
          // Safe: content is sanitized before rendering.
          dangerouslySetInnerHTML={{ __html: safeHTML }}
        />
      )}
    </article>
  );
}
