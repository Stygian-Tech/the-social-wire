"use client";

import { useCallback, useMemo, useState } from "react";
import { Archive, ChevronLeft, ExternalLink, Settings, Trash2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { EntryArticleEmbed } from "@/components/EntryDetail/EntryArticleEmbed";
import { Button, buttonVariants } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useArchiveHttpsReadLaterMutation,
  useDeleteHttpsReadLaterMutation,
  useLatrMergedHttpsSaves,
} from "@/hooks/useLatrSaved";
import { useConfiguredReadLaterService } from "@/hooks/useReadLaterPreferences";
import { READ_LATER_SERVICES } from "@/lib/readLaterServices";
import { cn } from "@/lib/utils";
import type { MergedLatrSave } from "@/lib/pdsClient";

function hostnamePreview(urlStr: string): string {
  try {
    return new URL(urlStr).hostname;
  } catch {
    return "—";
  }
}

function rowId(row: MergedLatrSave): string {
  return row.kind === "external" ? `external:${row.normalizedUrl}` : `native:${row.itemUri}`;
}

function rowTitle(row: MergedLatrSave): string {
  if (row.title?.trim()) return row.title.trim();
  const url = rowUrl(row);
  if (url) return hostnamePreview(url);
  return row.subjectUri;
}

function rowSubtitle(row: MergedLatrSave): string {
  const url = rowUrl(row);
  const source = url ? hostnamePreview(url) : row.subjectUri;
  return `${source} · ${new Date(row.savedAt).toLocaleString()}`;
}

function rowUrl(row: MergedLatrSave): string | undefined {
  return row.url;
}

export default function SavedPage() {
  const router = useRouter();
  const { data = [], isLoading, isError, error } = useLatrMergedHttpsSaves();
  const archiveMut = useArchiveHttpsReadLaterMutation();
  const deleteMut = useDeleteHttpsReadLaterMutation();
  const {
    service: configuredService,
    serviceId,
  } = useConfiguredReadLaterService();
  const configuredServiceIsLatr = serviceId === "latr-link";
  const configuredServiceLabel =
    READ_LATER_SERVICES.find((s) => s.id === serviceId)?.label ??
    configuredService.label;

  const [selectedRowId, setSelectedRowId] = useState<string | null>(null);

  const resolvedSelectedRowId =
    selectedRowId !== null && data.some((r) => rowId(r) === selectedRowId)
      ? selectedRowId
      : null;

  const selectedRow = useMemo(
    () => data.find((r) => rowId(r) === resolvedSelectedRowId) ?? null,
    [data, resolvedSelectedRowId]
  );

  const handleDelete = useCallback(
    (normalizedUrl: string) => {
      deleteMut.mutate(normalizedUrl);
      setSelectedRowId((prev) => (prev === `external:${normalizedUrl}` ? null : prev));
    },
    [deleteMut]
  );

  const handleArchive = useCallback(
    (normalizedUrl: string) => {
      archiveMut.mutate(normalizedUrl);
      setSelectedRowId((prev) => (prev === `external:${normalizedUrl}` ? null : prev));
    },
    [archiveMut]
  );

  const embedTitle = selectedRow ? rowTitle(selectedRow) : "";
  const selectedUrl = selectedRow ? rowUrl(selectedRow) : undefined;

  const detailEmptyMessage =
    !configuredService.connected ? (
      <p>Connect your read-later service to preview saves here.</p>
    ) : !configuredServiceIsLatr ? (
      <p>
        This layout will show an embedded preview when supported for your provider.
      </p>
    ) : isLoading ? (
      <p>Loading…</p>
    ) : (
      <p>Select a saved link from the list</p>
    );

  const listPane = (() => {
    if (!configuredService.connected) {
      return (
        <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 p-4 text-center md:p-6">
          <div className="max-w-lg space-y-2">
            <h2 className="text-sm font-medium">
              Connect {configuredServiceLabel}
            </h2>
            <p className="text-sm text-muted-foreground">
              Log in to {configuredServiceLabel} to load saved links from that service.
            </p>
          </div>
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => router.push("/saved/settings")}
          >
            Read Later Settings
          </Button>
        </div>
      );
    }

    if (!configuredServiceIsLatr) {
      return (
        <div className="flex min-h-0 flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground">
          List view for this read-later provider is not available yet. Open a saved link from{" "}
          {configuredServiceLabel} elsewhere, or switch to LATR Link in settings.
        </div>
      );
    }

    if (isLoading) {
      return (
        <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto overscroll-y-contain p-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <Skeleton key={i} className="h-20 w-full shrink-0 rounded-md" />
          ))}
        </div>
      );
    }

    if (isError) {
      return (
        <div className="flex min-h-0 flex-1 items-start p-3">
          <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive">
            {error instanceof Error ? error.message : "Could not load saved links"}
          </p>
        </div>
      );
    }

    if (data.length === 0) {
      return (
        <div className="flex min-h-0 flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground">
          Nothing queued yet — use Save on an article toolbar to add this page&apos;s HTTPS URL.
        </div>
      );
    }

    return (
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-y-contain">
        {data.map((row) => {
          const id = rowId(row);
          return (
            <button
              key={id}
              type="button"
              onClick={() => setSelectedRowId(id)}
              className={cn(
                "flex w-full gap-3 border-b px-4 py-3 text-left transition-colors hover:bg-muted/50",
                resolvedSelectedRowId === id && "bg-muted"
              )}
            >
              {row.image ? (
                <>
                  {/* eslint-disable-next-line @next/next/no-img-element -- user/PDS supplied OpenGraph URLs are not Next image domains. */}
                  <img
                    src={row.image}
                    alt=""
                    className="mt-0.5 size-12 shrink-0 rounded-md border border-border object-cover"
                    loading="lazy"
                  />
                </>
              ) : null}
              <div className="min-w-0 flex-1">
                <p className="line-clamp-2 text-sm font-medium leading-snug">
                  {rowTitle(row)}
                </p>
                {row.excerpt ? (
                  <p className="mt-1 line-clamp-2 text-xs leading-snug text-muted-foreground">
                    {row.excerpt}
                  </p>
                ) : null}
                <p className="mt-1 truncate text-[11px] text-muted-foreground">
                  {rowSubtitle(row)}
                </p>
              </div>
            </button>
          );
        })}
      </div>
    );
  })();

  return (
    <div className="flex h-full min-h-0 max-h-full flex-1 flex-col overflow-hidden md:flex-row md:items-stretch">
      <aside
        className={cn(
          "flex min-h-0 min-w-0 flex-col overflow-hidden border-r bg-muted/20",
          "w-full flex-1 md:h-full md:w-72 md:shrink-0 md:flex-none",
          resolvedSelectedRowId && "hidden md:flex"
        )}
      >
        <div className="flex shrink-0 items-center justify-between gap-2 border-b px-3 py-2">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
            {configuredServiceLabel}
          </p>
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            className="size-8 shrink-0"
            aria-label="Open Read Later Settings"
            title="Open Read Later Settings"
            onClick={() => router.push("/saved/settings")}
          >
            <Settings className="size-4" />
          </Button>
        </div>
        {listPane}
      </aside>

      <div
        className={cn(
          "flex min-h-0 min-w-0 flex-1 flex-col md:h-full md:overflow-hidden",
          !resolvedSelectedRowId && "hidden md:flex",
          resolvedSelectedRowId &&
            "overflow-x-hidden overflow-y-auto overscroll-y-contain md:overflow-hidden"
        )}
      >
        {selectedRow ? (
          <>
            <div className="bg-background sticky top-0 z-10 flex min-h-[44px] shrink-0 flex-wrap items-center gap-2 border-b px-1 py-1 md:static md:z-0 md:flex-nowrap md:px-4 md:py-2">
              <div className="flex min-h-[44px] min-w-0 flex-1 items-center gap-1 md:min-h-0">
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  className="size-11 shrink-0 rounded-lg md:hidden"
                  aria-label="Back to Saved Links"
                  onClick={() => setSelectedRowId(null)}
                >
                  <ChevronLeft className="size-5" />
                </Button>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium leading-snug">{embedTitle}</p>
                  <p className="truncate text-[11px] text-muted-foreground">
                    {selectedUrl
                      ? hostnamePreview(selectedUrl)
                      : selectedRow.subjectUri}
                  </p>
                </div>
              </div>
              <div className="flex w-full shrink-0 items-center justify-end gap-2 px-2 pb-2 md:w-auto md:px-0 md:pb-0">
                {selectedUrl ? (
                  <a
                    href={selectedUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className={buttonVariants({
                      variant: "outline",
                      size: "sm",
                      className: "gap-1.5",
                    })}
                  >
                    <ExternalLink className="size-3.5" />
                    Open
                  </a>
                ) : null}
                {selectedRow.kind === "external" ? (
                  <>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="gap-1.5"
                      disabled={archiveMut.isPending}
                      onClick={() => handleArchive(selectedRow.normalizedUrl)}
                      title="Archive Read Later Item"
                    >
                      <Archive className="size-3.5" />
                      Archive
                    </Button>
                    <Button
                      type="button"
                      variant="destructive"
                      size="sm"
                      className="gap-1.5"
                      disabled={deleteMut.isPending}
                      onClick={() => handleDelete(selectedRow.normalizedUrl)}
                      title="Remove from Read Later"
                    >
                      <Trash2 className="size-3.5" />
                      Remove
                    </Button>
                  </>
                ) : null}
              </div>
            </div>

            <div className="flex min-h-0 flex-1 flex-col overflow-hidden px-4 py-2">
              {selectedUrl ? (
                <EntryArticleEmbed
                  url={selectedUrl}
                  title={embedTitle}
                  className="min-h-[40vh] flex-1 border border-border md:min-h-0"
                />
              ) : (
                <div className="flex min-h-[40vh] flex-1 items-center justify-center rounded-md border border-border p-8 text-center text-sm text-muted-foreground">
                  Native ATProto saved item previews are not available yet.
                </div>
              )}
            </div>
          </>
        ) : (
          <div className="flex flex-1 flex-col items-center justify-center gap-3 p-8 text-center text-sm text-muted-foreground">
            {detailEmptyMessage}
          </div>
        )}
      </div>
    </div>
  );
}
