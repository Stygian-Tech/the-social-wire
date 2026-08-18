"use client";

import { useEffect, useMemo, useRef } from "react";
import { ExternalLink, X } from "lucide-react";

import { ArticleContent } from "@/components/EntryDetail/ArticleContent";
import { Skeleton } from "@/components/ui/skeleton";
import { useEntry } from "@/hooks/useEntries";
import { outboundLinkProps } from "@/lib/outboundLinks";
import { sanitizeHTMLWithLinks } from "@/lib/sanitize";

export function RssArticleReaderDialog({
  open,
  entryId,
  originalUrl,
  title,
  onClose,
}: {
  open: boolean;
  entryId: string | null;
  originalUrl: string | null;
  title: string;
  onClose: () => void;
}) {
  const entryQuery = useEntry(open ? entryId : null);

  return (
    <RssArticleReaderDialogView
      open={open}
      entryId={entryId}
      originalUrl={originalUrl}
      title={title}
      onClose={onClose}
      entryQuery={entryQuery}
    />
  );
}

export function RssArticleReaderDialogView({
  open,
  entryId,
  originalUrl,
  title,
  onClose,
  entryQuery,
}: {
  open: boolean;
  entryId: string | null;
  originalUrl: string | null;
  title: string;
  onClose: () => void;
  entryQuery: {
    data?: { contentHtml?: string; summary?: string } | null;
    isLoading: boolean;
    error: unknown;
  };
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const safeHTML = useMemo(
    () =>
      sanitizeHTMLWithLinks(
        entryQuery.data?.contentHtml || entryQuery.data?.summary || "",
      ),
    [entryQuery.data?.contentHtml, entryQuery.data?.summary],
  );

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && entryId) {
      if (!dialog.open) dialog.showModal();
    } else if (dialog.open) {
      dialog.close();
    }
  }, [entryId, open]);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    dialog.addEventListener("close", onClose);
    return () => dialog.removeEventListener("close", onClose);
  }, [onClose]);

  return (
    <dialog
      ref={dialogRef}
      aria-labelledby="rss-article-reader-title"
      aria-modal="true"
      className="fixed left-1/2 top-1/2 z-[200] m-0 h-[min(92svh,900px)] w-[min(calc(100vw-2rem),48rem)] max-w-none -translate-x-1/2 -translate-y-1/2 overflow-hidden rounded-2xl border border-border bg-background p-0 text-foreground shadow-2xl outline-none open:flex open:flex-col [&::backdrop]:bg-black/60"
    >
      <header className="flex shrink-0 items-center justify-between gap-3 border-b border-border/70 px-4 py-3 sm:px-5">
        <h2
          id="rss-article-reader-title"
          title={title}
          className="min-w-0 truncate text-sm font-semibold"
        >
          {title || "RSS Article"}
        </h2>
        <div className="flex shrink-0 items-center gap-1">
          {originalUrl ? (
            <a
              href={originalUrl}
              {...outboundLinkProps}
              aria-label="Open Article on Original Site"
              title="Open on Original Site"
              className="inline-flex size-9 items-center justify-center rounded-xl text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            >
              <ExternalLink className="size-4" aria-hidden />
            </a>
          ) : null}
          <button
            type="button"
            aria-label="Close Reader"
            title="Close"
            onClick={() => dialogRef.current?.close()}
            className="inline-flex size-9 items-center justify-center rounded-xl text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          >
            <X className="size-4" aria-hidden />
          </button>
        </div>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-y-contain px-5 py-6 sm:px-8 sm:py-8">
        {entryQuery.isLoading ? (
          <div className="mx-auto max-w-[72ch] space-y-3">
            <Skeleton className="h-8 w-3/4" />
            {Array.from({ length: 8 }).map((_, index) => (
              <Skeleton key={index} className="h-4 w-full" />
            ))}
          </div>
        ) : entryQuery.error ? (
          <p className="text-sm text-muted-foreground">
            This feed content could not be loaded. Use the original-site button
            to continue reading.
          </p>
        ) : safeHTML ? (
          <ArticleContent html={safeHTML} />
        ) : (
          <p className="text-sm text-muted-foreground">
            This feed did not include article content. Use the original-site
            button to continue reading.
          </p>
        )}
      </div>
    </dialog>
  );
}
