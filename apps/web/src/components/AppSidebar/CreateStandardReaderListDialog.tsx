"use client";

import { useEffect, useRef, useState } from "react";
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
import { standardReaderListDisplayHandle } from "@/lib/standardReaderListDisplayHandle";
import type { StandardReaderListPublication } from "@/lib/standardReaderListsClient";
import {
  standardReaderListRecord,
  type CreateStandardReaderListInput,
} from "@/lib/standardReaderList";

export type StandardReaderListCreator = { did: string; handle?: string };
type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  publications: StandardReaderListPublication[];
  saving: boolean;
  onResolveCreator: (input: string) => Promise<StandardReaderListCreator>;
  onCreate: (input: CreateStandardReaderListInput) => Promise<unknown>;
};
const inputClass =
  "w-full min-w-0 rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring";

export function CreateStandardReaderListDialog({
  open,
  onOpenChange,
  publications,
  saving,
  onResolveCreator,
  onCreate,
}: Props) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [publicationFilter, setPublicationFilter] = useState("");
  const [publicationIds, setPublicationIds] = useState<string[]>([]);
  const [creatorInput, setCreatorInput] = useState("");
  const [creators, setCreators] = useState<StandardReaderListCreator[]>([]);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const epoch = useRef(0);
  useEffect(
    () => () => {
      epoch.current++;
    },
    [],
  );
  const changeOpen = (next: boolean) => {
    if (!next) epoch.current++;
    onOpenChange(next);
  };
  const addCreator = async () => {
    if (saving || pending || !creatorInput.trim() || creators.length >= 500)
      return;
    const captured = ++epoch.current;
    setPending(true);
    setError(null);
    try {
      const creator = await onResolveCreator(creatorInput.trim());
      if (captured !== epoch.current) return;
      setCreators((previous) =>
        previous.some((item) => item.did === creator.did)
          ? previous
          : [...previous, creator],
      );
      setCreatorInput("");
    } catch (failure) {
      if (captured === epoch.current)
        setError(
          failure instanceof Error
            ? failure.message
            : "Couldn't Find This Creator. Try Again.",
        );
    } finally {
      if (captured === epoch.current) setPending(false);
    }
  };
  const create = async () => {
    if (saving || pending || !name.trim()) return;
    const captured = ++epoch.current;
    setPending(true);
    setError(null);
    try {
      const input = {
        name: name.trim(),
        ...(description.trim() ? { description: description.trim() } : {}),
        publications: publicationIds,
        users: creators.map((creator) => creator.did),
      };
      standardReaderListRecord(input);
      await onCreate(input);
      if (captured === epoch.current) changeOpen(false);
    } catch (failure) {
      if (captured === epoch.current)
        setError(
          failure instanceof Error
            ? failure.message
            : "Couldn't Create This List. Try Again.",
        );
    } finally {
      if (captured === epoch.current) setPending(false);
    }
  };
  const filter = publicationFilter.trim().toLowerCase();
  const filteredPublications = publications.filter((publication) =>
    `${publication.title} ${standardReaderListDisplayHandle(publication.authorHandle) || ""}`
      .toLowerCase()
      .includes(filter),
  );
  return (
    <Dialog open={open} onOpenChange={changeOpen}>
      <DialogContent className="max-h-[min(85svh,44rem)] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Create List</DialogTitle>
          <DialogDescription>
            Choose publications and creator accounts for your list.
          </DialogDescription>
        </DialogHeader>
        <p className="text-xs text-muted-foreground">
          Lists and their members are public and may be copied by others.
          Creating a list does not subscribe you to its members.
        </p>
        <form
          id="create-reader-list"
          className="space-y-3"
          onSubmit={(event) => {
            event.preventDefault();
            void create();
          }}
        >
          <label className="grid gap-1.5 text-sm font-medium">
            List Name
            <input
              aria-label="List Name"
              className={inputClass}
              value={name}
              onChange={(event) => setName(event.target.value)}
              required
              disabled={saving || pending}
            />
          </label>
          <label className="grid gap-1.5 text-sm font-medium">
            Description
            <textarea
              aria-label="Description"
              className={inputClass}
              value={description}
              onChange={(event) => setDescription(event.target.value)}
              rows={2}
              disabled={saving || pending}
            />
          </label>
          <fieldset disabled={saving || pending} className="space-y-2">
            <legend className="mb-2 text-sm font-medium">Publications</legend>
            {publications.length ? (
              <>
                <label className="grid gap-1.5 text-sm font-medium">
                  Filter Publications
                  <input
                    aria-label="Filter Publications"
                    type="search"
                    value={publicationFilter}
                    onChange={(event) =>
                      setPublicationFilter(event.target.value)
                    }
                    onKeyDown={(event) => {
                      if (event.key === "Enter") event.preventDefault();
                    }}
                    className={inputClass}
                    placeholder="Publication Name Or Creator Handle"
                  />
                </label>
                <p className="text-xs text-muted-foreground">
                  {publicationIds.length} Selected
                </p>
                <div className="max-h-40 space-y-2 overflow-y-auto rounded-md border p-3">
                  {filteredPublications.map((publication) => (
                    <label
                      key={publication.publicationId}
                      className="flex items-start gap-2 text-sm"
                    >
                      <input
                        type="checkbox"
                        checked={publicationIds.includes(
                          publication.publicationId,
                        )}
                        disabled={
                          publicationIds.length >= 500 &&
                          !publicationIds.includes(publication.publicationId)
                        }
                        onChange={(event) =>
                          setPublicationIds((previous) =>
                            event.target.checked
                              ? [...previous, publication.publicationId]
                              : previous.filter(
                                  (id) => id !== publication.publicationId,
                                ),
                          )
                        }
                        className="mt-1"
                      />
                      <span className="min-w-0 break-words">
                        {publication.title}
                        {standardReaderListDisplayHandle(
                          publication.authorHandle,
                        ) ? (
                          <span className="block text-xs text-muted-foreground">
                            @
                            {standardReaderListDisplayHandle(
                              publication.authorHandle,
                            )}
                          </span>
                        ) : null}
                      </span>
                    </label>
                  ))}
                  {!filteredPublications.length ? (
                    <p role="status" className="text-sm text-muted-foreground">
                      No Matching Publications.
                    </p>
                  ) : null}
                </div>
              </>
            ) : (
              <p className="text-sm text-muted-foreground">
                No Available Publications. You Can Add Creator Accounts Below.
              </p>
            )}
          </fieldset>
        </form>
        <form
          className="space-y-2"
          onSubmit={(event) => {
            event.preventDefault();
            void addCreator();
          }}
        >
          <label className="grid gap-1.5 text-sm font-medium">
            Creator Account
            <input
              aria-label="Creator Account"
              placeholder="Creator Handle Or DID"
              className={inputClass}
              value={creatorInput}
              onChange={(event) => setCreatorInput(event.target.value)}
              disabled={saving || pending}
            />
          </label>
          <Button
            type="submit"
            variant="outline"
            disabled={
              saving ||
              pending ||
              !creatorInput.trim() ||
              creators.length >= 500
            }
          >
            Add Creator
          </Button>
        </form>
        {creators.length ? (
          <ul className="space-y-2">
            {creators.map((creator) => (
              <li
                key={creator.did}
                className="flex min-w-0 items-center justify-between gap-2 text-sm"
              >
                <span className="min-w-0 break-words">
                  {standardReaderListDisplayHandle(creator.handle)
                    ? `@${standardReaderListDisplayHandle(creator.handle)}`
                    : creator.did}
                </span>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  disabled={saving || pending}
                  aria-label={`Remove ${creator.handle || creator.did}`}
                  onClick={() =>
                    setCreators((previous) =>
                      previous.filter((item) => item.did !== creator.did),
                    )
                  }
                >
                  Remove
                </Button>
              </li>
            ))}
          </ul>
        ) : null}
        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        ) : null}
        <DialogFooter className="sticky bottom-0 z-10 bg-popover">
          <DialogClose render={<Button type="button" variant="outline" />}>
            Cancel
          </DialogClose>
          <Button
            type="submit"
            form="create-reader-list"
            disabled={saving || pending || !name.trim()}
          >
            {saving || pending ? "Working…" : "Create List"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
