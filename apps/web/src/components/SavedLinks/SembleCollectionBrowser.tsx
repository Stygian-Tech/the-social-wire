"use client";

import { useMemo, useState } from "react";
import { ExternalLink, Link2, NotebookPen, Trash2 } from "lucide-react";

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
import { Skeleton } from "@/components/ui/skeleton";
import {
  SembleLinkCreationError,
  useCreateSembleNoteMutation,
  useCreateSembleConnectionMutation,
  useRemoveSembleMembershipMutation,
  useRetrySembleLinkMutation,
  useSaveToSembleMutation,
  useSembleCollectionItems,
  useSembleConnections,
  useUpdateSembleNoteMutation,
  useUpdateSembleConnectionMutation,
} from "@/hooks/useSembleReadLater";
import type { SembleReadLaterConnectionPreference } from "@/lib/pdsClient";
import type { SembleConnection, SembleSavedItem } from "@/lib/semble";
import { SembleReadError } from "@/lib/sembleClient";
import type { SembleStrongRef } from "@/lib/semblePdsClient";
import { OUTBOUND_WINDOW_FEATURES } from "@/lib/outboundLinks";

function itemTitle(item: SembleSavedItem): string {
  return item.title?.trim() || item.siteName?.trim() || item.url?.trim() || "Semble Note";
}

function itemDate(item: SembleSavedItem): string {
  const raw = item.membership?.addedAt ?? item.createdAt;
  if (!raw) return "";
  const date = new Date(raw);
  return Number.isNaN(date.valueOf())
    ? raw
    : date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function SembleItemDetail({
  item,
  collectionUri,
  onClose,
  onRemove,
  membershipComplete,
  recordLinksComplete,
}: {
  item: SembleSavedItem;
  collectionUri: string;
  onClose: () => void;
  onRemove: (item: SembleSavedItem) => void;
  membershipComplete: boolean;
  recordLinksComplete: boolean;
}) {
  const [noteValue, setNoteValue] = useState(item.note?.text ?? "");
  const connections = useSembleConnections(collectionUri, item.url);
  const createConnection = useCreateSembleConnectionMutation(
    collectionUri,
    item.url ?? "",
  );
  const updateConnection = useUpdateSembleConnectionMutation(
    collectionUri,
    item.url ?? "",
  );
  const createNote = useCreateSembleNoteMutation(collectionUri);
  const updateNote = useUpdateSembleNoteMutation(collectionUri);
  const notePending = createNote.isPending || updateNote.isPending;
  const [connectionUri, setConnectionUri] = useState<string | null>(null);
  const [connectionTarget, setConnectionTarget] = useState("");
  const [connectionType, setConnectionType] = useState("RELATED");
  const [connectionNote, setConnectionNote] = useState("");
  const saveNote = () => {
    const text = noteValue.trim();
    if (!text) return;
    if (item.note) {
      if (!item.note.editable || !item.note.uri) return;
      updateNote.mutate(
        { noteUri: item.note.uri, text },
        { onSuccess: onClose },
      );
      return;
    }
    if (!item.cardCid) return;
    createNote.mutate(
      { card: { uri: item.cardUri, cid: item.cardCid }, text },
      { onSuccess: onClose },
    );
  };
  const resetConnectionEditor = () => {
    setConnectionUri(null);
    setConnectionTarget("");
    setConnectionType("RELATED");
    setConnectionNote("");
  };
  const editConnection = (connection: SembleConnection) => {
    if (!connection.editable || !connection.uri) return;
    setConnectionUri(connection.uri);
    setConnectionTarget(connection.target);
    setConnectionType(connection.connectionType || "RELATED");
    setConnectionNote(connection.note ?? "");
  };
  const saveConnection = () => {
    const input = {
      target: connectionTarget,
      connectionType,
      note: connectionNote.trim() || undefined,
    };
    if (connectionUri) {
      updateConnection.mutate(
        { uri: connectionUri, ...input },
        { onSuccess: resetConnectionEditor },
      );
    } else {
      createConnection.mutate(input, { onSuccess: resetConnectionEditor });
    }
  };

  return (
    <Dialog open onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="max-h-[85svh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{itemTitle(item)}</DialogTitle>
          <DialogDescription>
            Added by {item.contributor.displayName || item.contributor.handle || item.contributor.did}
            {itemDate(item) ? ` on ${itemDate(item)}` : ""}.
          </DialogDescription>
        </DialogHeader>
        {item.image ? (
          // eslint-disable-next-line @next/next/no-img-element -- Semble preserves publisher image URLs.
          <img src={item.image} alt="" className="max-h-64 w-full rounded-lg border object-cover" />
        ) : null}
        {item.description ? (
          <p className="text-sm leading-6 text-muted-foreground">{item.description}</p>
        ) : null}
        {!membershipComplete || !recordLinksComplete ? (
          <p role="status" className="rounded-md border border-amber-500/30 bg-amber-500/10 p-2 text-xs text-amber-900 dark:text-amber-200">
            Semble is still linking this projected item to its records. Editing and removal become available when syncing finishes.
          </p>
        ) : null}
        {item.url ? (
          <Button
            type="button"
            variant="outline"
            className="w-full justify-start gap-2"
            onClick={() => window.open(item.url, "_blank", OUTBOUND_WINDOW_FEATURES)}
          >
            <ExternalLink className="size-4" />
            Open Original
          </Button>
        ) : null}
        <label className="grid gap-1.5 text-sm font-medium">
          {item.note ? "Edit Note" : "Add Note"}
          <textarea
            value={noteValue}
            onChange={(event) => setNoteValue(event.target.value)}
            placeholder="Why are you saving this?"
            className="min-h-24 rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          />
        </label>
        {(item.note && (!item.note.editable || !item.note.uri)) ||
        (!item.note && !item.cardCid) ? (
          <p className="text-xs text-muted-foreground">
            This note is read-only until its viewer-owned record link is available.
          </p>
        ) : null}
        {item.url ? (
          <section className="rounded-lg border p-3">
            <h3 className="flex items-center gap-2 text-sm font-semibold">
              <Link2 className="size-4" /> Connections
            </h3>
            {connections.connections.length ? (
            <ul className="mt-2 space-y-2 text-xs text-muted-foreground">
              {connections.connections.map((connection, index) => (
                <li
                  key={connection.uri ?? `${connection.source}:${connection.target}:${index}`}
                  className="flex items-start justify-between gap-2"
                >
                  <span>
                    {connection.connectionType || "Related"}: {connection.target}
                    {connection.note ? ` — ${connection.note}` : ""}
                  </span>
                  {connection.editable && connection.uri ? (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      onClick={() => editConnection(connection)}
                    >
                      Edit
                    </Button>
                  ) : null}
                </li>
              ))}
            </ul>
            ) : (
              <p className="mt-2 text-xs text-muted-foreground">No connections yet.</p>
            )}
            <div className="mt-3 grid gap-2 border-t pt-3">
              <Input
                value={connectionTarget}
                onChange={(event) => setConnectionTarget(event.target.value)}
                placeholder="Connected URL Or AT-URI"
                aria-label="Connected URL Or AT-URI"
              />
              <div className="grid grid-cols-[9rem_minmax(0,1fr)] gap-2">
                <select
                  value={connectionType}
                  onChange={(event) => setConnectionType(event.target.value)}
                  className="h-10 rounded-md border border-input bg-background px-2 text-sm"
                  aria-label="Connection Type"
                >
                  {[
                    "RELATED",
                    "SUPPORTS",
                    "OPPOSES",
                    "ADDRESSES",
                    "HELPFUL",
                    "LEADS_TO",
                    "SUPPLEMENT",
                    "EXPLAINER",
                  ].map((type) => <option key={type}>{type}</option>)}
                </select>
                <Input
                  value={connectionNote}
                  onChange={(event) => setConnectionNote(event.target.value)}
                  placeholder="Optional Connection Note"
                />
              </div>
              <div className="flex justify-end gap-2">
                {connectionUri ? (
                  <Button type="button" variant="ghost" onClick={resetConnectionEditor}>
                    Cancel Edit
                  </Button>
                ) : null}
                <Button
                  type="button"
                  variant="outline"
                  disabled={
                    !connectionTarget.trim() ||
                    createConnection.isPending ||
                    updateConnection.isPending
                  }
                  onClick={saveConnection}
                >
                  {createConnection.isPending || updateConnection.isPending
                    ? "Saving…"
                    : connectionUri
                      ? "Update Connection"
                      : "Add Connection"}
                </Button>
              </div>
              {createConnection.error || updateConnection.error ? (
                <p role="alert" className="text-sm text-destructive">
                  {(createConnection.error ?? updateConnection.error)?.message}
                </p>
              ) : null}
            </div>
          </section>
        ) : null}
        {createNote.error || updateNote.error ? (
          <p role="alert" className="text-sm text-destructive">
            {(createNote.error ?? updateNote.error)?.message}
          </p>
        ) : null}
        <DialogFooter className="sm:justify-between">
          <Button
            type="button"
            variant="destructive"
            className="gap-2"
            disabled={!item.unlinkAvailable}
            onClick={() => onRemove(item)}
          >
            <Trash2 className="size-4" /> Remove From Collection
          </Button>
          <div className="flex gap-2">
            <DialogClose render={<Button type="button" variant="outline" />}>Close</DialogClose>
            <Button
              type="button"
              disabled={
                !noteValue.trim() ||
                notePending ||
                (item.note
                  ? !item.note.editable || !item.note.uri
                  : !item.cardCid)
              }
              onClick={saveNote}
            >
              {notePending ? "Saving…" : "Save Note"}
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function SembleCollectionBrowser({
  connection,
}: {
  connection: SembleReadLaterConnectionPreference;
}) {
  const collectionQuery = useSembleCollectionItems(connection.collectionUri);
  const saveMutation = useSaveToSembleMutation(connection.collectionUri);
  const retryMutation = useRetrySembleLinkMutation(connection.collectionUri);
  const removeMutation = useRemoveSembleMembershipMutation(connection.collectionUri);
  const [url, setUrl] = useState("");
  const [note, setNote] = useState("");
  const [selected, setSelected] = useState<SembleSavedItem | null>(null);

  const orphanCard =
    saveMutation.error instanceof SembleLinkCreationError
      ? saveMutation.error.orphanCard
      : null;
  const collectionName =
    collectionQuery.collection?.name || connection.collectionName;
  const count = collectionQuery.collection?.cardCount ?? collectionQuery.items.length;
  const collectionUnavailable =
    collectionQuery.error instanceof SembleReadError &&
    (collectionQuery.error.status === 403 || collectionQuery.error.status === 404);
  const orderedItems = useMemo(
    () =>
      [...collectionQuery.items].sort((left, right) =>
        (right.membership?.addedAt ?? right.createdAt ?? "").localeCompare(
          left.membership?.addedAt ?? left.createdAt ?? "",
        ),
      ),
    [collectionQuery.items],
  );

  const save = () => {
    saveMutation.mutate(
      { url, note: note.trim() || undefined },
      {
        onSuccess: () => {
          setUrl("");
          setNote("");
        },
      },
    );
  };
  const retry = (card: SembleStrongRef) => {
    retryMutation.mutate(card, { onSuccess: () => saveMutation.reset() });
  };
  const remove = (item: SembleSavedItem) => {
    removeMutation.mutate(item, {
      onSuccess: () => {
        if (selected?.id === item.id) setSelected(null);
      },
    });
  };

  return (
    <>
      <div className="mx-auto flex h-full min-h-0 w-full max-w-3xl flex-1 flex-col overflow-hidden border-x border-border/70 bg-background">
        <header className="border-b p-4">
          <div className="flex items-baseline justify-between gap-4">
            <div>
              <h2 className="text-base font-bold">{collectionName}</h2>
              <p className="text-xs text-muted-foreground">
                {count} {count === 1 ? "Item" : "Items"} · Semble Collection
              </p>
            </div>
          </div>
          <div className="mt-3 grid gap-2">
            <Input
              type="url"
              value={url}
              disabled={collectionUnavailable}
              onChange={(event) => setUrl(event.target.value)}
              placeholder="https://example.com/article"
              aria-label="URL To Save"
            />
            <div className="flex gap-2">
              <Input
                value={note}
                disabled={collectionUnavailable}
                onChange={(event) => setNote(event.target.value)}
                placeholder="Optional Note"
                aria-label="Optional Note"
              />
              <Button
                type="button"
                disabled={collectionUnavailable || !url.trim() || saveMutation.isPending}
                onClick={save}
              >
                {saveMutation.isPending ? "Saving…" : "Save"}
              </Button>
            </div>
          </div>
          {saveMutation.error ? (
            <div role="alert" className="mt-2 flex flex-wrap items-center gap-2 text-sm text-destructive">
              <span>{saveMutation.error.message}</span>
              {orphanCard ? (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={retryMutation.isPending}
                  onClick={() => retry(orphanCard)}
                >
                  {retryMutation.isPending ? "Retrying…" : "Retry Link"}
                </Button>
              ) : null}
            </div>
          ) : null}
          {retryMutation.error || removeMutation.error ? (
            <p role="alert" className="mt-2 text-sm text-destructive">
              {(retryMutation.error ?? removeMutation.error)?.message}
            </p>
          ) : null}
          {collectionQuery.isError && collectionQuery.items.length > 0 ? (
            <div
              role="status"
              className="mt-2 flex flex-wrap items-center gap-2 rounded-md border border-amber-500/30 bg-amber-500/10 p-2 text-xs text-amber-900 dark:text-amber-200"
            >
              <span>Showing cached Semble items because the live projection failed.</span>
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={collectionQuery.isFetching}
                onClick={() => collectionQuery.refetch()}
              >
                {collectionQuery.isFetching ? "Retrying…" : "Retry"}
              </Button>
            </div>
          ) : null}
        </header>
        {collectionQuery.isLoading ? (
          <div className="space-y-2 p-2">
            {Array.from({ length: 6 }).map((_, index) => (
              <Skeleton key={index} className="h-28 w-full rounded-lg" />
            ))}
          </div>
        ) : collectionQuery.isError && collectionQuery.items.length === 0 ? (
          <div className="flex flex-1 flex-col items-center justify-center gap-3 p-8 text-center text-sm text-destructive">
            <p>{collectionQuery.error.message}</p>
            <p className="max-w-md text-xs text-muted-foreground">
              {collectionUnavailable
                ? "Choose another viewer-owned Semble collection in Your Account settings before saving again."
                : "Your cached collection remains available when present. Retry the projection request when Semble is reachable."}
            </p>
            <Button
              type="button"
              variant="outline"
              disabled={collectionQuery.isFetching}
              onClick={() => collectionQuery.refetch()}
            >
              {collectionQuery.isFetching ? "Retrying…" : "Retry"}
            </Button>
          </div>
        ) : orderedItems.length === 0 ? (
          <div className="flex flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground">
            This Semble collection is empty.
          </div>
        ) : (
          <div className="min-h-0 flex-1 overflow-y-auto p-2">
            {orderedItems.map((item) => (
              <button
                key={item.membership?.linkUri ?? item.id}
                type="button"
                className="mb-2 flex w-full gap-3 rounded-xl border bg-card p-3 text-left shadow-sm transition-colors hover:bg-accent/40"
                onClick={() => setSelected(item)}
              >
                <div className="size-20 shrink-0 overflow-hidden rounded-lg border bg-muted/40">
                  {item.image ? (
                    // eslint-disable-next-line @next/next/no-img-element -- Semble preserves publisher image URLs.
                    <img src={item.image} alt="" className="size-full object-cover" />
                  ) : (
                    <NotebookPen className="m-6 size-8 text-muted-foreground" />
                  )}
                </div>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-xs text-muted-foreground">
                    {item.siteName || item.contributor.handle || item.contributor.did}
                    {itemDate(item) ? ` · ${itemDate(item)}` : ""}
                  </p>
                  <h3 className="mt-1 line-clamp-2 font-semibold">{itemTitle(item)}</h3>
                  {item.description ? (
                    <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">
                      {item.description}
                    </p>
                  ) : null}
                  {item.note ? (
                    <p className="mt-1 line-clamp-1 text-xs text-muted-foreground">
                      Note: {item.note.text}
                    </p>
                  ) : null}
                </div>
              </button>
            ))}
            {collectionQuery.hasNextPage ? (
              <Button
                type="button"
                variant="outline"
                className="w-full"
                disabled={collectionQuery.isFetchingNextPage}
                onClick={() => collectionQuery.fetchNextPage()}
              >
                {collectionQuery.isFetchingNextPage ? "Loading…" : "Load More"}
              </Button>
            ) : null}
          </div>
        )}
      </div>
      {selected ? (
        <SembleItemDetail
          item={selected}
          collectionUri={connection.collectionUri}
          membershipComplete={collectionQuery.membershipComplete}
          recordLinksComplete={collectionQuery.recordLinksComplete}
          onClose={() => setSelected(null)}
          onRemove={remove}
        />
      ) : null}
    </>
  );
}
