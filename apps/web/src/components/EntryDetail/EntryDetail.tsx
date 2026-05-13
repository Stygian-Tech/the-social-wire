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
    [entry?.contentHtml]
  );

  if (isLoading) {
    return (
      <div className="space-y-4 p-8">
        <Skeleton className="h-8 w-3/4" />
        <Skeleton className="h-4 w-1/4" />
        <div className="space-y-2 pt-4">
          {Array.from({ length: 8 }).map((_, i) => (
            <Skeleton key={i} className="h-4 w-full" />
          ))}
        </div>
      </div>
    );
  }

  if (error || !entry) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-sm text-muted-foreground">
        Failed to load entry.
      </div>
    );
  }

  const date = new Date(entry.publishedAt).toLocaleDateString(undefined, {
    year: "numeric",
    month: "long",
    day: "numeric",
  });

  const showEmbed = Boolean(entry.embedUrl);

  return (
    <article className="mx-auto max-w-4xl p-8">
      <header className="mb-4">
        <h1 className="text-2xl font-bold leading-tight">{entry.title}</h1>
        <div className="mt-2 flex flex-wrap items-center gap-3 text-sm text-muted-foreground">
          <time dateTime={entry.publishedAt}>{date}</time>
          {(entry.embedUrl ?? entry.originalUrl) && (
            <a
              href={entry.embedUrl ?? entry.originalUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1 hover:text-foreground transition-colors"
            >
              <ExternalLink className="h-3.5 w-3.5" />
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
          className="mb-8"
        />
      ) : null}

      {!showEmbed && !safeHTML.trim() ? (
        <p className="text-sm text-muted-foreground">
          No embed URL or HTML body is available for this entry.
        </p>
      ) : (
        <div className="space-y-2">
          {showEmbed ? (
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              Syndicated HTML
            </p>
          ) : null}
          <div
            className="prose prose-sm dark:prose-invert max-w-none"
            // Safe: content is sanitized before rendering.
            dangerouslySetInnerHTML={{ __html: safeHTML }}
          />
        </div>
      )}
    </article>
  );
}
