"use client";

import { useCallback, useMemo, useState } from "react";
import { Archive, ArchiveRestore, ChevronLeft, ExternalLink, Trash2 } from "lucide-react";
import { EntryArticleEmbed } from "@/components/EntryDetail/EntryArticleEmbed";
import { DevRecordKindBadge } from "@/components/shared/DevRecordKindBadge";
import { ListColumnError } from "@/components/shared/ListColumnError";
import {
  READER_LIST_COLUMN_WIDTH_KEY,
  ResizableListColumn,
} from "@/components/shared/ResizableListColumn";
import { SavedLinkPublicationChip } from "@/components/SavedLinks/SavedLinkPublicationChip";
import { SavedLinkSocialToolbar } from "@/components/SavedLinks/SavedLinkSocialToolbar";
import { SavedLinkRowActions } from "@/components/SavedLinks/SavedLinkRowActions";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import { Button, buttonVariants } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useArchiveLatrSaveMutation,
  useDeleteLatrSaveMutation,
  useLatrMergedHttpsSaves,
  useUnarchiveLatrSaveMutation,
} from "@/hooks/useLatrSaved";
import type { LatrSaveListState, MergedLatrSave } from "@/lib/pdsClient";
import { recordKindFromLatrSave } from "@/lib/recordKindDebug";
import {
  resolveSavedLinkEmbedUrl,
  stableSavedLinkIframeSrc,
} from "@/lib/savedLinkEmbedUrl";
import {
  articleListCardButtonClassName,
  articleListCardWrapperClassName,
} from "@/lib/articleListCardStyles";
import { cn } from "@/lib/utils";

export type SavedLinksBrowserMode = "active" | "archived";

function hostnamePreview(urlStr: string): string {
  try {
    return new URL(urlStr).hostname;
  } catch {
    return "—";
  }
}

function rowId(row: MergedLatrSave): string {
  return row.kind === "external"
    ? `external:${row.normalizedUrl}`
    : `native:${row.itemUri}`;
}

function rowUrl(row: MergedLatrSave): string | undefined {
  return resolveSavedLinkEmbedUrl(row);
}

function rowTitle(row: MergedLatrSave): string {
  if (row.title?.trim()) return row.title.trim();
  const url = rowUrl(row);
  if (url) return hostnamePreview(url);
  return row.subjectUri;
}

function rowSiteLabel(row: MergedLatrSave): string {
  if (row.site?.trim()) return row.site.trim();
  const url = rowUrl(row);
  if (url) return hostnamePreview(url);
  return row.subjectUri;
}

function formatSavedAt(savedAt: string): string {
  const parsed = Date.parse(savedAt);
  if (Number.isNaN(parsed)) return savedAt;
  return new Date(parsed).toLocaleString();
}

function formatPublishedAt(publishedAt: string | undefined): string | null {
  if (!publishedAt?.trim()) return null;
  const parsed = Date.parse(publishedAt);
  if (Number.isNaN(parsed)) return publishedAt;
  return new Date(parsed).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function rowSubtitle(row: MergedLatrSave): string {
  const parts = [rowSiteLabel(row), formatSavedAt(row.savedAt)];
  const published = formatPublishedAt(row.publishedAt);
  if (published) parts.splice(1, 0, published);
  if (row.author?.trim()) parts.splice(1, 0, row.author.trim());
  return parts.join(" · ");
}

interface SavedLinksBrowserProps {
  mode: SavedLinksBrowserMode;
}

export function SavedLinksBrowser({ mode }: SavedLinksBrowserProps) {
  const listState: LatrSaveListState =
    mode === "archived" ? "archived" : "active";
  const {
    data = [],
    isLoading,
    isError,
    error,
  } = useLatrMergedHttpsSaves(listState);
  const archiveMut = useArchiveLatrSaveMutation();
  const unarchiveMut = useUnarchiveLatrSaveMutation();
  const deleteMut = useDeleteLatrSaveMutation();

  const isArchivedView = mode === "archived";
  const listHeaderLabel = isArchivedView ? "Archive" : "Saved";
  const emptyListMessage = isArchivedView
    ? "Nothing archived"
    : "Nothing saved";
  const backLabel = isArchivedView
    ? "Back to Archived Links"
    : "Back to Saved Links";

  const [selectedRowId, setSelectedRowId] = useState<string | null>(null);

  const resolvedSelectedRowId =
    selectedRowId !== null && data.some((r) => rowId(r) === selectedRowId)
      ? selectedRowId
      : null;

  const selectedRow = useMemo(
    () => data.find((r) => rowId(r) === resolvedSelectedRowId) ?? null,
    [data, resolvedSelectedRowId],
  );

  const clearSelectionIfNeeded = useCallback((row: MergedLatrSave) => {
    setSelectedRowId((prev) => (prev === rowId(row) ? null : prev));
  }, []);

  const handleDelete = useCallback(
    (row: MergedLatrSave) => {
      deleteMut.mutate(row.itemRkey);
      clearSelectionIfNeeded(row);
    },
    [clearSelectionIfNeeded, deleteMut],
  );

  const handleArchive = useCallback(
    (row: MergedLatrSave) => {
      archiveMut.mutate(row.itemRkey);
      clearSelectionIfNeeded(row);
    },
    [archiveMut, clearSelectionIfNeeded],
  );

  const handleUnarchive = useCallback(
    (row: MergedLatrSave) => {
      unarchiveMut.mutate(row.itemRkey);
      clearSelectionIfNeeded(row);
    },
    [clearSelectionIfNeeded, unarchiveMut],
  );

  const embedTitle = selectedRow ? rowTitle(selectedRow) : "";
  const selectedUrl = selectedRow ? rowUrl(selectedRow) : undefined;
  const selectedIframeSrc = selectedRow
    ? stableSavedLinkIframeSrc(selectedRow)
    : undefined;
  const selectedFallbackContent = selectedRow ? (
    <article className="space-y-3">
      {selectedRow.image ? (
        // eslint-disable-next-line @next/next/no-img-element -- saved-link thumbnails are remote publisher metadata.
        <img
          src={selectedRow.image}
          alt=""
          className="max-h-72 w-full rounded-lg object-cover"
        />
      ) : null}
      <div className="space-y-1">
        <h2 className="text-xl font-semibold tracking-tight text-foreground">
          {rowTitle(selectedRow)}
        </h2>
        <p className="text-sm text-muted-foreground">
          {rowSubtitle(selectedRow)}
        </p>
      </div>
      {selectedRow.excerpt ? (
        <p className="max-w-3xl text-base leading-7 text-foreground/85">
          {selectedRow.excerpt}
        </p>
      ) : null}
    </article>
  ) : undefined;

  const detailEmptyMessage = isLoading ? (
    <p>Loading…</p>
  ) : data.length === 0 ? (
    <p>{emptyListMessage}</p>
  ) : (
    <p>Select an article</p>
  );

  const listPane = (() => {
    if (isLoading) {
      return (
        <div className="flex min-h-0 flex-1 flex-col gap-1.5 overflow-y-auto overscroll-y-contain p-2 pt-2">
          {Array.from({ length: 6 }).map((_, i) => (
            <Skeleton key={i} className="h-36 w-full shrink-0 rounded-lg" />
          ))}
        </div>
      );
    }

    if (isError) {
      return (
        <ListColumnError
          error={error}
          fallbackTitle="Could not load saved links"
        />
      );
    }

    if (data.length === 0) {
      return (
        <div className="flex min-h-0 flex-1 items-center justify-center p-8 text-center">
          <p className="text-sm text-muted-foreground">{emptyListMessage}</p>
        </div>
      );
    }

    return (
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-y-contain pt-2">
        {data.map((row) => {
          const id = rowId(row);
          const card = (
            <button
              type="button"
              onClick={() => setSelectedRowId(id)}
              className={articleListCardButtonClassName({
                isSelected: resolvedSelectedRowId === id,
              })}
            >
              <div className="relative aspect-[16/9] w-full shrink-0 overflow-hidden bg-muted/40">
                {row.image ? (
                  <>
                    {/* eslint-disable-next-line @next/next/no-img-element -- user/PDS supplied OpenGraph URLs are not Next image domains. */}
                    <img
                      src={row.image}
                      alt=""
                      className="absolute inset-0 size-full object-cover"
                      loading="lazy"
                    />
                  </>
                ) : null}
                <div
                  className="absolute left-2 top-2 z-10 max-w-[calc(100%-1rem)]"
                  onClick={(e) => e.stopPropagation()}
                  onKeyDown={(e) => e.stopPropagation()}
                >
                  <SavedLinkPublicationChip row={row} overlay />
                </div>
              </div>
              <div className="min-w-0 px-4 py-3">
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
                <DevRecordKindBadge
                  info={recordKindFromLatrSave(row)}
                  className="mt-1"
                />
              </div>
            </button>
          );

          return (
            <div key={id} className={articleListCardWrapperClassName}>
              <ContextMenu>
                <ContextMenuTrigger className="flex w-full min-w-0 outline-none">
                  {card}
                </ContextMenuTrigger>
                <ContextMenuContent className="min-w-[11rem]">
                  <SavedLinkRowActions
                    row={row}
                    isArchivedView={isArchivedView}
                    onArchive={handleArchive}
                    onUnarchive={handleUnarchive}
                    onDelete={handleDelete}
                  />
                </ContextMenuContent>
              </ContextMenu>
            </div>
          );
        })}
      </div>
    );
  })();

  return (
    <div className="flex h-full min-h-0 max-h-full flex-1 flex-col overflow-hidden md:flex-row md:items-stretch">
      <ResizableListColumn
        storageKey={READER_LIST_COLUMN_WIDTH_KEY}
        hiddenOnMobile={Boolean(resolvedSelectedRowId)}
      >
        <div className="flex shrink-0 items-center border-b bg-background/75 px-3 py-2 backdrop-blur-md">
          <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">
            {listHeaderLabel}
          </p>
        </div>
        {listPane}
      </ResizableListColumn>

      <div
        className={cn(
          "flex min-h-0 min-w-0 flex-1 flex-col md:h-full md:overflow-hidden",
          !resolvedSelectedRowId && "hidden md:flex",
          resolvedSelectedRowId && "overflow-hidden",
        )}
      >
        {selectedRow ? (
          <>
            <div className="sticky top-0 z-10 shrink-0 border-b bg-background/90 px-1.5 py-1.5 backdrop-blur-md md:static md:z-0 md:bg-background/75 md:px-4 md:py-2">
              <div className="flex min-h-[44px] flex-wrap items-center gap-2 md:min-h-0 md:flex-nowrap">
                <div className="flex min-h-[44px] min-w-0 flex-1 items-center gap-1 md:min-h-0">
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    className="size-11 shrink-0 md:hidden"
                    aria-label={backLabel}
                    onClick={() => setSelectedRowId(null)}
                  >
                    <ChevronLeft className="size-5" />
                  </Button>
                  <div className="min-w-0 flex-1">
                    <SavedLinkPublicationChip
                      row={selectedRow}
                      className="mb-1.5 md:hidden"
                    />
                    <p className="truncate text-sm font-medium leading-snug">
                      {embedTitle}
                    </p>
                    <p className="truncate text-[11px] text-muted-foreground">
                      {rowSubtitle(selectedRow)}
                    </p>
                    <DevRecordKindBadge
                      info={recordKindFromLatrSave(selectedRow)}
                      className="mt-1"
                    />
                  </div>
                </div>
                <div className="grid w-full shrink-0 grid-cols-3 gap-2 px-2 pb-2 max-md:hidden md:flex md:w-auto md:items-center md:justify-end md:px-0 md:pb-0">
                  {selectedUrl ? (
                    <a
                      href={selectedUrl}
                      target="_blank"
                      rel="noopener noreferrer"
                      className={buttonVariants({
                        variant: "outline",
                        size: "sm",
                        className: "min-w-0 gap-1.5",
                      })}
                    >
                      <ExternalLink className="size-3.5" />
                      Open
                    </a>
                  ) : null}
                  {isArchivedView ? (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="min-w-0 gap-1.5"
                      onClick={() => handleUnarchive(selectedRow)}
                      title="Unarchive Read Later Item"
                    >
                      <ArchiveRestore className="size-3.5" />
                      Unarchive
                    </Button>
                  ) : (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="min-w-0 gap-1.5"
                      onClick={() => handleArchive(selectedRow)}
                      title="Archive Read Later Item"
                    >
                      <Archive className="size-3.5" />
                      Archive
                    </Button>
                  )}
                  <Button
                    type="button"
                    variant="destructive"
                    size="sm"
                    className="min-w-0 gap-1.5"
                    onClick={() => handleDelete(selectedRow)}
                    title="Remove from Read Later"
                  >
                    <Trash2 className="size-3.5" />
                    Delete
                  </Button>
                </div>
              </div>
            </div>
            <SavedLinkSocialToolbar
              row={selectedRow}
              className="mt-1 px-2 md:px-4"
              extraActions={
                <>
                  {isArchivedView ? (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="h-11 min-h-[44px] justify-center gap-1.5 px-2 md:hidden"
                      onClick={() => handleUnarchive(selectedRow)}
                      title="Unarchive Read Later Item"
                      aria-label="Unarchive Read Later Item"
                    >
                      <ArchiveRestore className="size-5 shrink-0" />
                      <span className="sr-only">Unarchive</span>
                    </Button>
                  ) : (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="h-11 min-h-[44px] justify-center gap-1.5 px-2 md:hidden"
                      onClick={() => handleArchive(selectedRow)}
                      title="Archive Read Later Item"
                      aria-label="Archive Read Later Item"
                    >
                      <Archive className="size-5 shrink-0" />
                      <span className="sr-only">Archive</span>
                    </Button>
                  )}
                  <Button
                    type="button"
                    variant="destructive"
                    size="sm"
                    className="h-11 min-h-[44px] justify-center gap-1.5 px-2 md:hidden"
                    onClick={() => handleDelete(selectedRow)}
                    title="Remove from Read Later"
                    aria-label="Remove from Read Later"
                  >
                    <Trash2 className="size-5 shrink-0" />
                    <span className="sr-only">Delete</span>
                  </Button>
                </>
              }
            />

            <div className="flex min-h-0 flex-1 scroll-pb-[calc(env(safe-area-inset-bottom)+6.25rem)] flex-col overflow-y-auto overflow-x-hidden overscroll-y-contain px-3 py-2 pb-[calc(env(safe-area-inset-bottom)+6.25rem)] sm:px-4 md:pb-2">
              {selectedIframeSrc ? (
                <EntryArticleEmbed
                  url={selectedIframeSrc}
                  title={embedTitle}
                  className="min-h-[40vh] flex-1 border border-border md:min-h-0"
                  fallbackContent={selectedFallbackContent}
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
