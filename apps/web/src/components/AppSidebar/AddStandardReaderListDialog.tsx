"use client";

import { useEffect, useRef, useState } from "react";
import { LoaderCircle, Plus } from "lucide-react";
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
import type { StandardReaderList } from "@/lib/standardReaderListsClient";

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  lists: StandardReaderList[];
  creatorResults: StandardReaderList[];
  searching: boolean;
  saving: boolean;
  onSearchCreator: (creator: string) => Promise<unknown>;
  onAdd: (input: string) => Promise<unknown>;
  onCreate?: () => void;
};
const inputClass =
  "h-10 w-full min-w-0 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring";
export function AddStandardReaderListDialog({
  open,
  onOpenChange,
  lists,
  creatorResults,
  searching,
  saving,
  onSearchCreator,
  onAdd,
  onCreate,
}: Props) {
  const [input, setInput] = useState("");
  const [creator, setCreator] = useState("");
  const [searched, setSearched] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<"search" | "add" | null>(null);
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
  const add = async (value: string) => {
    if (saving || pending || !value.trim()) return;
    const captured = ++epoch.current;
    setError(null);
    setPending("add");
    try {
      await onAdd(value.trim());
      if (epoch.current === captured) changeOpen(false);
    } catch (failure) {
      if (epoch.current === captured)
        setError(
          failure instanceof Error
            ? failure.message
            : "Couldn't Add This List. Try Again.",
        );
    } finally {
      if (epoch.current === captured) setPending(null);
    }
  };
  const search = async () => {
    if (searching || pending || !creator.trim()) return;
    const captured = ++epoch.current;
    setError(null);
    setSearched(false);
    setPending("search");
    try {
      await onSearchCreator(creator.trim());
      if (epoch.current === captured) setSearched(true);
    } catch (failure) {
      if (epoch.current === captured)
        setError(
          failure instanceof Error
            ? failure.message
            : "Couldn't Find This Creator's Lists. Try Again.",
        );
    } finally {
      if (epoch.current === captured) setPending(null);
    }
  };
  const saved = new Set(lists.map((list) => list.uri));
  return (
    <Dialog open={open} onOpenChange={changeOpen}>
      <DialogContent className="max-h-[min(85svh,44rem)] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Add List</DialogTitle>
          <DialogDescription>
            Paste a Standard Reader list URL or AT URI, or find a creator&apos;s
            public lists.
          </DialogDescription>
        </DialogHeader>
        <p className="text-xs text-muted-foreground">
          Saved lists are public. Saving a list does not subscribe you to its
          members.
        </p>
        <form
          className="space-y-3"
          onSubmit={(event) => {
            event.preventDefault();
            void add(input);
          }}
        >
          <label className="grid gap-1.5 text-sm font-medium">
            List URL Or AT URI
            <input
              aria-label="List URL Or AT URI"
              placeholder="https://standard-reader.app/l/… or at://…"
              value={input}
              onChange={(event) => setInput(event.target.value)}
              className={inputClass}
              required
              disabled={saving || pending !== null}
            />
          </label>
          <Button
            type="submit"
            disabled={saving || pending !== null || !input.trim()}
            className="w-full"
          >
            {saving || pending === "add" ? "Adding…" : "Add List"}
          </Button>
        </form>
        <div className="border-t pt-4">
          <form
            className="space-y-3"
            onSubmit={(event) => {
              event.preventDefault();
              void search();
            }}
          >
            <label className="grid gap-1.5 text-sm font-medium">
              List Creator
              <input
                aria-label="List Creator"
                placeholder="Creator Handle Or DID"
                value={creator}
                onChange={(event) => {
                  setCreator(event.target.value);
                  setSearched(false);
                }}
                className={inputClass}
                required
                disabled={saving || pending !== null}
              />
            </label>
            <Button
              type="submit"
              variant="outline"
              disabled={
                searching || saving || pending !== null || !creator.trim()
              }
              className="w-full"
            >
              {searching || pending === "search" ? (
                <LoaderCircle
                  aria-hidden="true"
                  className="size-4 animate-spin"
                />
              ) : null}
              Find Creator&apos;s Lists
            </Button>
          </form>
          {searched && !searching && pending !== "search" ? (
            creatorResults.length ? (
              <ul className="mt-3 space-y-2">
                {creatorResults.map((list) => (
                  <li
                    key={list.uri}
                    className="flex min-w-0 items-center gap-2 rounded-md border p-2"
                  >
                    <div className="min-w-0 flex-1">
                      <p className="break-words text-sm font-medium">
                        {list.name}
                      </p>
                      {list.description ? (
                        <p className="break-words text-xs text-muted-foreground">
                          {list.description}
                        </p>
                      ) : null}
                    </div>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      aria-label={`Add ${list.name}`}
                      disabled={
                        saved.has(list.uri) || saving || pending !== null
                      }
                      onClick={() => void add(list.uri)}
                    >
                      {saved.has(list.uri) ? (
                        "Added"
                      ) : (
                        <>
                          <Plus aria-hidden="true" className="size-3.5" />
                          Add
                        </>
                      )}
                    </Button>
                  </li>
                ))}
              </ul>
            ) : (
              <p role="status" className="mt-3 text-sm text-muted-foreground">
                No Public Lists Found For This Creator.
              </p>
            )
          ) : null}
        </div>
        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        ) : null}
        <DialogFooter>
          {onCreate ? (
            <Button
              type="button"
              variant="outline"
              disabled={saving || pending !== null}
              onClick={() => {
                changeOpen(false);
                onCreate();
              }}
            >
              Create List
            </Button>
          ) : null}
          <DialogClose render={<Button type="button" variant="outline" />}>
            Cancel
          </DialogClose>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
