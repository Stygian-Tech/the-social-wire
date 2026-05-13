"use client";

import { useMemo } from "react";
import { ExternalLink } from "lucide-react";
import { EntryArticleEmbed } from "@/components/EntryDetail/EntryArticleEmbed";
import { EntrySocialToolbar } from "@/components/EntryDetail/EntrySocialToolbar";
import { Skeleton } from "@/components/ui/skeleton";
import { useEntry } from "@/hooks/useEntries";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
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

  const canonicalArticleHref =
    entry?.embedUrl ?? entry?.originalUrl
      ? normalizeHttpUrlToHttps(
          entry?.embedUrl ?? entry?.originalUrl ?? ""
        )
      : undefined;

  if (isLoading) {
    return (
      <div className="space-y-4 p-4 sm:p-6">
        <Skeleton className="h-10 w-full max-w-xs" />
        <div className="space-y-2">
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

  const showEmbed = Boolean(entry.embedUrl) && !preferRecordBodyOverEmbed;

  return (
    <article className="flex min-h-0 w-full max-w-none flex-1 flex-col px-3 pb-8 pt-1 sm:px-4 sm:pb-10 sm:pt-2 md:px-6 lg:px-8">
      <EntrySocialToolbar entry={entry} />

      {canonicalArticleHref && !showEmbed ? (
        <div className="mt-3 flex flex-wrap sm:mt-4">
          <a
            href={canonicalArticleHref}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex min-h-[44px] min-w-0 items-center gap-1 py-2 text-xs text-muted-foreground transition-colors hover:text-foreground sm:min-h-0 sm:text-sm sm:py-0"
          >
            <ExternalLink className="h-3.5 w-3.5 shrink-0" />
            View original
          </a>
        </div>
      ) : null}

      {showEmbed ? (
        <div className="mb-5 flex min-h-0 flex-1 flex-col sm:mb-6">
          <EntryArticleEmbed
            url={entry.embedUrl!}
            title={entry.title}
            className="min-h-0 flex-1"
          />
        </div>
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
