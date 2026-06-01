"use client";

import { useCallback, useMemo, useState } from "react";
import {
  Archive,
  ArchiveRestore,
  ChevronLeft,
  ExternalLink,
  Settings,
  Trash2,
} from "lucide-react";
import { useRouter } from "next/navigation";
import { EntryArticleEmbed } from "@/components/EntryDetail/EntryArticleEmbed";
import { DevRecordKindBadge } from "@/components/shared/DevRecordKindBadge";
import { ListColumnError } from "@/components/shared/ListColumnError";
import {
  READER_LIST_COLUMN_WIDTH_KEY,
  ResizableListColumn,
} from "@/components/shared/ResizableListColumn";
import { SavedLinkPublicationChip } from "@/components/SavedLinks/SavedLinkPublicationChip";
import { SavedLinkSocialToolbar } from "@/components/SavedLinks/SavedLinkSocialToolbar";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
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
import { useConfiguredReadLaterService } from "@/hooks/useReadLaterPreferences";
import { READ_LATER_SERVICES, isLatrPdsReadLaterService } from "@/lib/readLaterServices";
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
  return row.kind === "external" ? `external:${row.normalizedUrl}` : `native:${row.itemUri}`;
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

function SavedLinkRowActions({
  row,
  isArchivedView,
  archivePending,
  unarchivePending,
  deletePending,
  onArchive,
  onUnarchive,
  onDelete,
}: {
  row: MergedLatrSave;
  isArchivedView: boolean;
  archivePending: boolean;
  unarchivePending: boolean;
  deletePending: boolean;
  onArchive: (row: MergedLatrSave) => void;
  onUnarchive: (row: MergedLatrSave) => void;
  onDelete: (row: MergedLatrSave) => void;
}) {
  return (
    <>
      {isArchivedView ? (
        <ContextMenuItem
          className="gap-2"
          disabled={unarchivePending}
          onClick={() => onUnarchive(row)}
        >
          <ArchiveRestore className="size-4" />
          Unarchive
        </ContextMenuItem>
      ) : (
        <ContextMenuItem
          className="gap-2"
          disabled={archivePending}
          onClick={() => onArchive(row)}
        >
          <Archive className="size-4" />
          Archive
        </ContextMenuItem>
      )}
      <ContextMenuSeparator />
      <ContextMenuItem
        variant="destructive"
        className="gap-2"
        disabled={deletePending}
        onClick={() => onDelete(row)}
      >
        <Trash2 className="size-4" />
        Delete
      </ContextMenuItem>
    </>
  );
}

interface SavedLinksBrowserProps {
  mode: SavedLinksBrowserMode;
}

export function SavedLinksBrowser({ mode }: SavedLinksBrowserProps) {
  const router = useRouter();
  const listState: LatrSaveListState = mode === "archived" ? "archived" : "active";
  const { data = [], isLoading, isError, error } = useLatrMergedHttpsSaves(listState);
  const archiveMut = useArchiveLatrSaveMutation();
  const unarchiveMut = useUnarchiveLatrSaveMutation();
  const deleteMut = useDeleteLatrSaveMutation();
  const {
    service: configuredService,
    serviceId,
  } = useConfiguredReadLaterService();
  const configuredServiceIsLatr = isLatrPdsReadLaterService(serviceId);
  const configuredServiceLabel =
    READ_LATER_SERVICES.find((s) => s.id === serviceId)?.label ??
    configuredService.label;

  const isArchivedView = mode === "archived";
  const emptyListMessage = isArchivedView ? "Nothing archived" : "Nothing saved";
  const backLabel = isArchivedView ? "Back to Archived Links" : "Back to Saved Links";

  const [selectedRowId, setSelectedRowId] = useState<string | null>(null);

  const resolvedSelectedRowId =
    selectedRowId !== null && data.some((r) => rowId(r) === selectedRowId)
      ? selectedRowId
      : null;

  const selectedRow = useMemo(
    () => data.find((r) => rowId(r) === resolvedSelectedRowId) ?? null,
    [data, resolvedSelectedRowId]
  );

  const clearSelectionIfNeeded = useCallback(
    (row: MergedLatrSave) => {
      setSelectedRowId((prev) => (prev === rowId(row) ? null : prev));
    },
    []
  );

  const handleDelete = useCallback(
    (row: MergedLatrSave) => {
      deleteMut.mutate(row.itemRkey);
      clearSelectionIfNeeded(row);
    },
    [clearSelectionIfNeeded, deleteMut]
  );

  const handleArchive = useCallback(
    (row: MergedLatrSave) => {
      archiveMut.mutate(row.itemRkey);
      clearSelectionIfNeeded(row);
    },
    [archiveMut, clearSelectionIfNeeded]
  );

  const handleUnarchive = useCallback(
    (row: MergedLatrSave) => {
      unarchiveMut.mutate(row.itemRkey);
      clearSelectionIfNeeded(row);
    },
    [clearSelectionIfNeeded, unarchiveMut]
  );

  const embedTitle = selectedRow ? rowTitle(selectedRow) : "";
  const selectedUrl = selectedRow ? rowUrl(selectedRow) : undefined;
  const selectedIframeSrc = selectedRow
    ? stableSavedLinkIframeSrc(selectedRow)
    : undefined;

  const detailEmptyMessage =
    !configuredService.connected ? (
      <p>Connect your read-later service to preview saves here.</p>
    ) : !configuredServiceIsLatr ? (
      <p>
        This layout will show an embedded preview when supported for your provider.
      </p>
    ) : isLoading ? (
      <p>Loading…</p>
    ) : data.length === 0 ? (
      <p>{emptyListMessage}</p>
    ) : (
      <p>Select an article</p>
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
          {configuredServiceLabel} elsewhere, or switch to L@tr.link or LatrKit in settings.
        </div>
      );
    }

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
                    archivePending={archiveMut.isPending}
                    unarchivePending={unarchiveMut.isPending}
                    deletePending={deleteMut.isPending}
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
        <div className="flex shrink-0 items-center justify-between gap-2 border-b px-3 py-2">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
            {isArchivedView ? "Archive" : configuredServiceLabel}
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
      </ResizableListColumn>

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
            <div className="bg-background sticky top-0 z-10 shrink-0 border-b px-1 py-1 md:static md:z-0 md:px-4 md:py-2">
              <div className="flex min-h-[44px] flex-wrap items-center gap-2 md:min-h-0 md:flex-nowrap">
                <div className="flex min-h-[44px] min-w-0 flex-1 items-center gap-1 md:min-h-0">
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    className="size-11 shrink-0 rounded-lg md:hidden"
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
                    <p className="truncate text-sm font-medium leading-snug">{embedTitle}</p>
                    <p className="truncate text-[11px] text-muted-foreground">
                      {rowSubtitle(selectedRow)}
                    </p>
                    <DevRecordKindBadge
                      info={recordKindFromLatrSave(selectedRow)}
                      className="mt-1"
                    />
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
                  {isArchivedView ? (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="gap-1.5"
                      disabled={unarchiveMut.isPending}
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
                      className="gap-1.5"
                      disabled={archiveMut.isPending}
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
                    className="gap-1.5"
                    disabled={deleteMut.isPending}
                    onClick={() => handleDelete(selectedRow)}
                    title="Remove from Read Later"
                  >
                    <Trash2 className="size-3.5" />
                    Delete
                  </Button>
                </div>
              </div>
              <SavedLinkSocialToolbar row={selectedRow} className="mt-1 px-2 md:px-0" />
            </div>

            <div className="flex min-h-0 flex-1 flex-col overflow-hidden px-4 py-2">
              {selectedIframeSrc ? (
                <EntryArticleEmbed
                  url={selectedIframeSrc}
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
