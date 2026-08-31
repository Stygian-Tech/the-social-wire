"use client";

import { useCallback, useMemo, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";

import { RssArticleReaderDialog } from "@/components/EntryDetail/RssArticleReaderDialog";
import { SavedLinkPublicationChip } from "@/components/SavedLinks/SavedLinkPublicationChip";
import { SavedLinkCardActions } from "@/components/SavedLinks/SavedLinkCardActions";
import { SavedLinkRowActions } from "@/components/SavedLinks/SavedLinkRowActions";
import { SavedLinksTagToolbar } from "@/components/SavedLinks/SavedLinksTagToolbar";
import { ListColumnError } from "@/components/shared/ListColumnError";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { useSidebarProjection } from "@/contexts/PublicationSidebarContext";
import {
  useArchiveLatrSaveMutation,
  useDeleteLatrSaveMutation,
  useLatrMergedHttpsSaves,
  useSetLatrSaveTagsMutation,
  useUnarchiveLatrSaveMutation,
} from "@/hooks/useLatrSaved";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import { useAuth } from "@/hooks/useAuth";
import {
  articleListCardWrapperClassName,
  articleListRowButtonClassName,
} from "@/lib/articleListCardStyles";
import { OUTBOUND_WINDOW_FEATURES } from "@/lib/outboundLinks";
import type { LatrSaveListState, MergedLatrSave } from "@/lib/pdsClient";
import { sidebarPublicationRows } from "@/lib/publicationProjectionClient";
import { savedFeedSourceKey } from "@/lib/savedFeedSources";
import { savedLinkOpenTarget } from "@/lib/savedLinkOpenTarget";
import { resolveEntryOpenUrlFromPds } from "@/lib/resolveEntryOpenUrl";
import { countLatrTags, filterLatrSavesByExactTag, parseLatrTagInput } from "@/lib/latrTags";

export type SavedLinksBrowserMode = "active" | "archived";

function rowId(row: MergedLatrSave): string {
  return row.kind === "external"
    ? `external:${row.normalizedUrl}`
    : `native:${row.itemUri}`;
}

function rowTitle(row: MergedLatrSave): string {
  if (row.title?.trim()) return row.title.trim();
  return row.site?.trim() || row.subjectUri;
}

function rowMetadata(row: MergedLatrSave): string {
  const savedAt = new Date(row.savedAt);
  const date = Number.isNaN(savedAt.valueOf())
    ? row.savedAt
    : savedAt.toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
        year:
          savedAt.getFullYear() !== new Date().getFullYear()
            ? "numeric"
            : undefined,
      });
  return [row.author, date].filter(Boolean).join(" · ");
}

export function SavedLinksBrowser({ mode }: { mode: SavedLinksBrowserMode }) {
  const searchParams = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();
  const sourceFilter = searchParams.get("source");
  const tagFilter = searchParams.get("tag");
  const { publicationSidebarProjection } = useSidebarProjection();
  const listState: LatrSaveListState =
    mode === "archived" ? "archived" : "active";
  const { data = [], isLoading, isError, error, migrationWarning } =
    useLatrMergedHttpsSaves(listState);
  const sidebarRows = useMemo(
    () =>
      publicationSidebarProjection
        ? sidebarPublicationRows(publicationSidebarProjection)
        : [],
    [publicationSidebarProjection],
  );
  const filteredData = useMemo(() => {
    const sourceRows = sourceFilter
        ? data.filter(
            (row) => savedFeedSourceKey(row, sidebarRows) === sourceFilter,
          )
        : data;
    return filterLatrSavesByExactTag(sourceRows, tagFilter);
  }, [data, sidebarRows, sourceFilter, tagFilter]);
  const viewTagCounts = useMemo(() => countLatrTags(data), [data]);
  const archiveMutation = useArchiveLatrSaveMutation();
  const unarchiveMutation = useUnarchiveLatrSaveMutation();
  const deleteMutation = useDeleteLatrSaveMutation();
  const setTagsMutation = useSetLatrSaveTagsMutation();
  const { preferences } = useFeedDisplayPreferences();
  const { getOAuthSession } = useAuth();
  const [rssReader, setRssReader] = useState<{
    row: MergedLatrSave;
    entryId: string;
    url: string;
  } | null>(null);
  const [tagEditorRow, setTagEditorRow] = useState<MergedLatrSave | null>(null);
  const [tagEditorValue, setTagEditorValue] = useState("");
  const isArchivedView = mode === "archived";

  const selectTag = useCallback(
    (tag: string | null) => {
      const params = new URLSearchParams(searchParams.toString());
      if (tag) params.set("tag", tag);
      else params.delete("tag");
      const query = params.toString();
      router.replace(query ? `${pathname}?${query}` : pathname);
    },
    [pathname, router, searchParams],
  );

  const openTagEditor = useCallback((row: MergedLatrSave) => {
    setTagsMutation.reset();
    setTagEditorRow(row);
    setTagEditorValue((row.tags ?? []).join(", "));
  }, [setTagsMutation]);

  const saveEditedTags = useCallback(() => {
    if (!tagEditorRow) return;
    setTagsMutation.mutate(
      {
        bookmarkUri: tagEditorRow.itemRkey,
        tags: parseLatrTagInput(tagEditorValue),
      },
      { onSuccess: () => setTagEditorRow(null) },
    );
  }, [setTagsMutation, tagEditorRow, tagEditorValue]);

  const closeReaderForRow = useCallback((row: MergedLatrSave) => {
    setRssReader((current) =>
      current && rowId(current.row) === rowId(row) ? null : current,
    );
  }, []);

  const handleArchive = useCallback(
    (row: MergedLatrSave) => {
      archiveMutation.mutate(row.itemRkey);
      closeReaderForRow(row);
    },
    [archiveMutation, closeReaderForRow],
  );

  const handleUnarchive = useCallback(
    (row: MergedLatrSave) => {
      unarchiveMutation.mutate(row.itemRkey);
      closeReaderForRow(row);
    },
    [closeReaderForRow, unarchiveMutation],
  );

  const handleDelete = useCallback(
    (row: MergedLatrSave) => {
      deleteMutation.mutate(row.itemRkey);
      closeReaderForRow(row);
    },
    [closeReaderForRow, deleteMutation],
  );

  const openRow = useCallback(
    (row: MergedLatrSave) => {
      const target = savedLinkOpenTarget(
        row,
        sidebarRows,
        preferences.rssArticleOpenMode,
      );
      if (!target) {
        const subject = row.subjectUri.trim();
        if (!subject.startsWith("at://")) return;
        const pendingTab = window.open("", "_blank");
        if (pendingTab) pendingTab.opener = null;
        void resolveEntryOpenUrlFromPds(
          subject,
          getOAuthSession() ?? undefined,
        ).then((resolvedUrl) => {
          if (!resolvedUrl) {
            pendingTab?.close();
            return;
          }
          if (pendingTab) pendingTab.location.href = resolvedUrl;
          else window.open(resolvedUrl, "_blank", OUTBOUND_WINDOW_FEATURES);
        });
        return;
      }
      if (target.kind === "rssReader") {
        setRssReader({ row, entryId: target.entryId, url: target.url });
        return;
      }
      window.open(target.url, "_blank", OUTBOUND_WINDOW_FEATURES);
    },
    [getOAuthSession, preferences.rssArticleOpenMode, sidebarRows],
  );

  let content;
  if (isLoading) {
    content = (
      <div className="space-y-2 p-2">
        {Array.from({ length: 7 }).map((_, index) => (
          <Skeleton key={index} className="h-32 w-full rounded-lg" />
        ))}
      </div>
    );
  } else if (isError) {
    content = (
      <ListColumnError
        error={error}
        fallbackTitle="Could not load saved links"
      />
    );
  } else if (filteredData.length === 0) {
    content = (
      <div className="flex flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground">
        {isArchivedView ? "Nothing archived" : "Nothing saved"}
      </div>
    );
  } else {
    content = (
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-y-contain pt-2">
        {filteredData.map((row) => {
          const id = rowId(row);
          const card = (
            <div
              role="button"
              tabIndex={0}
              onClick={() => openRow(row)}
              onKeyDown={(event) => {
                if (event.key !== "Enter" && event.key !== " ") return;
                event.preventDefault();
                openRow(row);
              }}
              className={articleListRowButtonClassName({
                isSelected: rssReader ? rowId(rssReader.row) === id : false,
              })}
            >
              <div className="relative aspect-[1.08] w-full self-center overflow-hidden rounded-md border border-border/70 bg-muted/40">
                {row.image ? (
                  // eslint-disable-next-line @next/next/no-img-element -- publisher/PDS image URLs are arbitrary.
                  <img
                    src={row.image}
                    alt=""
                    loading="lazy"
                    className="absolute inset-0 size-full object-cover"
                  />
                ) : null}
              </div>
              <div className="flex min-w-0 flex-col gap-1">
                <div
                  className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground"
                  onClick={(event) => event.stopPropagation()}
                  onKeyDown={(event) => event.stopPropagation()}
                >
                  <SavedLinkPublicationChip
                    row={row}
                    className="max-w-[12rem] border-0 bg-transparent px-0 py-0 text-foreground/80"
                  />
                  <span aria-hidden>•</span>
                  <span>{rowMetadata(row)}</span>
                </div>
                {row.tags?.length ? (
                  <div className="flex min-w-0 flex-wrap gap-1">
                    {row.tags.map((tag) => (
                      <button
                        key={tag}
                        type="button"
                        className="rounded-full border border-border/70 bg-muted/50 px-2 py-0.5 text-xs font-medium text-muted-foreground hover:text-foreground"
                        onClick={(event) => {
                          event.stopPropagation();
                          selectTag(tag);
                        }}
                        onKeyDown={(event) => event.stopPropagation()}
                      >
                        {tag}
                      </button>
                    ))}
                  </div>
                ) : null}
                <p
                  className={`line-clamp-2 text-base font-semibold leading-snug text-foreground underline-offset-4 group-hover:underline ${row.excerpt ? "" : "pr-24"}`}
                >
                  {rowTitle(row)}
                </p>
                {row.excerpt ? (
                  <p className="line-clamp-2 pr-24 text-sm leading-5 text-muted-foreground">
                    {row.excerpt}
                  </p>
                ) : null}
                <div className="absolute bottom-2.5 right-2.5 flex items-center">
                  <SavedLinkCardActions
                    row={row}
                    isArchivedView={isArchivedView}
                    disabled={
                      archiveMutation.isPending ||
                      unarchiveMutation.isPending ||
                      deleteMutation.isPending
                    }
                    onOpen={openRow}
                    onEditTags={openTagEditor}
                    onArchive={handleArchive}
                    onUnarchive={handleUnarchive}
                    onDelete={handleDelete}
                  />
                </div>
              </div>
            </div>
          );

          return (
            <div
              key={id}
              className={`${articleListCardWrapperClassName} group`}
            >
              <ContextMenu>
                <ContextMenuTrigger className="flex w-full min-w-0 outline-none">
                  {card}
                </ContextMenuTrigger>
                <ContextMenuContent className="min-w-[11rem]">
                  <SavedLinkRowActions
                    row={row}
                    isArchivedView={isArchivedView}
                    onEditTags={openTagEditor}
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
  }

  return (
    <>
      <div className="mx-auto flex h-full min-h-0 w-full max-w-3xl flex-1 flex-col overflow-hidden border-x border-border/70 bg-background">
        <SavedLinksTagToolbar
          viewTagCounts={viewTagCounts}
          selectedTag={tagFilter}
          showSaveComposer={!isArchivedView}
          onSelectTag={selectTag}
        />
        {migrationWarning ? (
          <div
            role="status"
            className="border-b border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm text-amber-900 dark:text-amber-200"
          >
            {migrationWarning}
          </div>
        ) : null}
        {content}
      </div>
      <RssArticleReaderDialog
        open={rssReader !== null}
        entryId={rssReader?.entryId ?? null}
        originalUrl={rssReader?.url ?? null}
        title={rssReader ? rowTitle(rssReader.row) : ""}
        onClose={() => setRssReader(null)}
      />
      <Dialog
        open={tagEditorRow !== null}
        onOpenChange={(open) => {
          if (!open) setTagEditorRow(null);
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Edit Tags</DialogTitle>
            <DialogDescription>
              Replace the tags for this saved article. Leave the field empty to clear them.
            </DialogDescription>
          </DialogHeader>
          <label className="grid gap-1.5 text-sm font-medium">
            Tags
            <Input
              value={tagEditorValue}
              onChange={(event) => setTagEditorValue(event.target.value)}
              placeholder="Research, Weekend"
            />
          </label>
          {setTagsMutation.error ? (
            <p role="alert" className="text-sm text-destructive">
              {setTagsMutation.error.message}
            </p>
          ) : null}
          <DialogFooter>
            <DialogClose render={<Button type="button" variant="outline" />}>Cancel</DialogClose>
            <Button type="button" disabled={setTagsMutation.isPending} onClick={saveEditedTags}>
              {setTagsMutation.isPending ? "Saving…" : "Save Tags"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
