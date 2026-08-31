"use client";

import { useMemo, useState } from "react";
import { Pencil, Plus, Tags, Trash2 } from "lucide-react";

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
import {
  useDeleteLatrTagPageMutation,
  useLatrTags,
  useRenameLatrTagPageMutation,
  useSaveHttpsReadLaterMutation,
} from "@/hooks/useLatrSaved";
import { parseLatrTagInput } from "@/lib/latrTags";

type TagOperation = {
  kind: "rename" | "delete";
  tag: string;
  replacement: string;
  cursor?: string;
  scanned: number;
  matched: number;
  updated: number;
  incomplete?: boolean;
};

export function SavedLinksTagToolbar({
  selectedTag,
  viewTagCounts,
  showSaveComposer,
  onSelectTag,
}: {
  selectedTag: string | null;
  viewTagCounts: Array<{ tag: string; count: number }>;
  showSaveComposer: boolean;
  onSelectTag: (tag: string | null) => void;
}) {
  const tagsQuery = useLatrTags();
  const saveMutation = useSaveHttpsReadLaterMutation();
  const renameMutation = useRenameLatrTagPageMutation();
  const deleteMutation = useDeleteLatrTagPageMutation();
  const [saveOpen, setSaveOpen] = useState(false);
  const [manageOpen, setManageOpen] = useState(false);
  const [url, setUrl] = useState("");
  const [tagInput, setTagInput] = useState("");
  const [operation, setOperation] = useState<TagOperation | null>(null);
  const tagCounts = tagsQuery.data ?? [];
  const saveTags = useMemo(() => parseLatrTagInput(tagInput), [tagInput]);
  const operationMutation = operation?.kind === "rename" ? renameMutation : deleteMutation;

  function handleSaveOpenChange(open: boolean) {
    setSaveOpen(open);
    if (open) {
      setUrl("");
      setTagInput(selectedTag ?? "");
      saveMutation.reset();
    }
  }

  function submitSave(event: React.FormEvent) {
    event.preventDefault();
    const trimmedURL = url.trim();
    if (!trimmedURL) return;
    saveMutation.mutate(
      { url: trimmedURL, tags: saveTags },
      { onSuccess: () => setSaveOpen(false) }
    );
  }

  function startOperation(kind: TagOperation["kind"], tag: string) {
    renameMutation.reset();
    deleteMutation.reset();
    setOperation({
      kind,
      tag,
      replacement: kind === "rename" ? tag : "",
      scanned: 0,
      matched: 0,
      updated: 0,
    });
  }

  function runOperation() {
    if (!operation) return;
    operationMutation.mutate(
      {
        tag: operation.tag,
        replacement: operation.replacement,
        cursor: operation.cursor,
      },
      {
        onSuccess: (page) => {
          const nextCursor = page.cursor?.trim() ||
            (page.ok ? undefined : operation.cursor);
          if (page.ok && !nextCursor && selectedTag === operation.tag) {
            onSelectTag(
              operation.kind === "rename" ? operation.replacement.trim() : null
            );
          }
          setOperation((current) =>
            current
              ? {
                  ...current,
                  cursor: nextCursor,
                  scanned: current.scanned + page.scanned,
                  matched: current.matched + page.matched,
                  updated: current.updated + page.updated,
                  incomplete: !page.ok,
                }
              : null
          );
        },
      }
    );
  }

  return (
    <>
      <div className="flex shrink-0 flex-col gap-2 border-b border-border/70 px-3 py-2">
        <div className="flex items-center gap-2 overflow-x-auto">
          <Button
            type="button"
            size="sm"
            variant={selectedTag ? "ghost" : "secondary"}
            onClick={() => onSelectTag(null)}
          >
            All Tags
          </Button>
          {viewTagCounts.map(({ tag, count }) => (
            <Button
              key={tag}
              type="button"
              size="sm"
              variant={selectedTag === tag ? "secondary" : "ghost"}
              onClick={() => onSelectTag(tag)}
              aria-pressed={selectedTag === tag}
            >
              {tag} <span className="text-muted-foreground">{count}</span>
            </Button>
          ))}
          <div className="ml-auto flex shrink-0 items-center gap-1">
            <Button type="button" size="sm" variant="outline" onClick={() => setManageOpen(true)}>
              <Tags className="size-4" />
              Manage Tags
            </Button>
            {showSaveComposer ? (
              <Button type="button" size="sm" onClick={() => handleSaveOpenChange(true)}>
                <Plus className="size-4" />
                Save With Tags
              </Button>
            ) : null}
          </div>
        </div>
      </div>

      <Dialog open={saveOpen} onOpenChange={handleSaveOpenChange}>
        <DialogContent className="sm:max-w-md">
          <form onSubmit={submitSave} className="space-y-4">
            <DialogHeader>
              <DialogTitle>Save With Tags</DialogTitle>
              <DialogDescription>
                Save an article URL and optionally add comma-separated tags.
              </DialogDescription>
            </DialogHeader>
            <label className="grid gap-1.5 text-sm font-medium">
              Article URL
              <Input
                type="url"
                required
                value={url}
                onChange={(event) => setUrl(event.target.value)}
                placeholder="https://example.com/article"
              />
            </label>
            <label className="grid gap-1.5 text-sm font-medium">
              Tags
              <Input
                value={tagInput}
                onChange={(event) => setTagInput(event.target.value)}
                placeholder="Research, Weekend"
              />
            </label>
            {saveMutation.error ? (
              <p role="alert" className="text-sm text-destructive">
                {saveMutation.error.message}
              </p>
            ) : null}
            <DialogFooter>
              <DialogClose render={<Button type="button" variant="outline" />}>Cancel</DialogClose>
              <Button type="submit" disabled={saveMutation.isPending || !url.trim()}>
                {saveMutation.isPending ? "Saving…" : "Save Article"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      <Dialog
        open={manageOpen}
        onOpenChange={(open) => {
          setManageOpen(open);
          if (open) setOperation(null);
        }}
      >
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Manage Tags</DialogTitle>
            <DialogDescription>
              Rename or delete tags in bounded batches. Resume until the operation is complete.
            </DialogDescription>
          </DialogHeader>
          <div className="max-h-56 space-y-1 overflow-y-auto">
            {tagCounts.map(({ tag, count }) => (
              <div key={tag} className="flex items-center gap-2 rounded-lg border px-3 py-2">
                <span className="min-w-0 flex-1 truncate text-sm font-medium">{tag}</span>
                <span className="text-xs text-muted-foreground">{count}</span>
                <Button type="button" size="icon-sm" variant="ghost" title={`Rename ${tag}`} aria-label={`Rename ${tag}`} onClick={() => startOperation("rename", tag)}>
                  <Pencil className="size-4" />
                </Button>
                <Button type="button" size="icon-sm" variant="ghost" className="text-destructive" title={`Delete ${tag}`} aria-label={`Delete ${tag}`} onClick={() => startOperation("delete", tag)}>
                  <Trash2 className="size-4" />
                </Button>
              </div>
            ))}
            {!tagsQuery.isLoading && tagCounts.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">No tags yet.</p>
            ) : null}
          </div>
          {operation ? (
            <div className="space-y-3 rounded-xl border bg-muted/20 p-3">
              <p className="text-sm font-semibold">
                {operation.kind === "rename" ? `Rename “${operation.tag}”` : `Delete “${operation.tag}”`}
              </p>
              {operation.kind === "rename" ? (
                <Input
                  aria-label="Replacement Tag"
                  value={operation.replacement}
                  onChange={(event) =>
                    setOperation((current) => current ? { ...current, replacement: event.target.value } : null)
                  }
                />
              ) : (
                <p className="text-sm text-muted-foreground">This removes the tag from matching saved articles.</p>
              )}
              {operation.scanned > 0 ? (
                <p className="text-xs text-muted-foreground">
                  Scanned {operation.scanned}; matched {operation.matched}; updated {operation.updated}.
                </p>
              ) : null}
              {operationMutation.error ? (
                <p role="alert" className="text-sm text-destructive">
                  {operationMutation.error.message} Resume from the last completed batch.
                </p>
              ) : null}
              {operation.incomplete ? (
                <p role="alert" className="text-sm text-destructive">
                  The last batch completed only partially. Progress is preserved; Resume will continue from the last safe cursor.
                </p>
              ) : null}
              {!operation.cursor && operation.scanned > 0 && !operation.incomplete ? (
                <p role="status" className="text-sm text-emerald-700 dark:text-emerald-400">Operation Complete</p>
              ) : (
                <Button
                  type="button"
                  variant={operation.kind === "delete" ? "destructive" : "default"}
                  disabled={operationMutation.isPending || (operation.kind === "rename" && !operation.replacement.trim())}
                  onClick={runOperation}
                >
                  {operationMutation.isPending
                    ? "Working…"
                    : operation.cursor || operation.incomplete || operationMutation.error
                      ? "Resume"
                      : operation.kind === "rename"
                        ? "Rename Tag"
                        : "Delete Tag"}
                </Button>
              )}
            </div>
          ) : null}
          <DialogFooter>
            <DialogClose render={<Button type="button" variant="outline" />}>Done</DialogClose>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
