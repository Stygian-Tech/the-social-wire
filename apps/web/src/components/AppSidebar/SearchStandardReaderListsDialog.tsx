"use client";

import { useState } from "react";
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
  loading: boolean;
  error?: string | null;
  onSelect: (uri: string) => void;
};
export function SearchStandardReaderListsDialog({
  open,
  onOpenChange,
  lists,
  loading,
  error,
  onSelect,
}: Props) {
  const [query, setQuery] = useState("");
  const matches = lists.filter(
    (list) =>
      (list.owned || list.saved) &&
      `${list.name} ${list.description ?? ""}`
        .toLocaleLowerCase()
        .includes(query.trim().toLocaleLowerCase()),
  );
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85svh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Search Lists</DialogTitle>
          <DialogDescription>
            Find a list you own or have saved. Use Add List to find another
            creator&apos;s lists.
          </DialogDescription>
        </DialogHeader>
        <label className="grid gap-1.5 text-sm font-medium">
          Filter Your Lists
          <input
            aria-label="Filter Your Lists"
            placeholder="Search Your Lists…"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            className="h-10 w-full min-w-0 rounded-md border border-input bg-background px-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          />
        </label>
        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        ) : null}
        {loading && !lists.length ? (
          <p role="status" className="text-sm text-muted-foreground">
            Loading Lists…
          </p>
        ) : null}
        {!loading && !error && !matches.length ? (
          <p role="status" className="text-sm text-muted-foreground">
            {query.trim() ? "No Matching Lists." : "No Lists Yet."}
          </p>
        ) : null}
        <ul aria-label="Your Lists Search Results" className="space-y-2">
          {matches.map((list) => (
            <li key={list.uri}>
              <Button
                type="button"
                variant="outline"
                aria-label={list.name}
                className="h-auto min-h-11 w-full justify-start whitespace-normal py-3 text-left"
                onClick={() => {
                  onOpenChange(false);
                  onSelect(list.uri);
                }}
              >
                <span className="min-w-0">
                  <span className="block break-words font-medium">
                    {list.name}
                  </span>
                  {list.description ? (
                    <span className="block break-words text-xs font-normal text-muted-foreground">
                      {list.description}
                    </span>
                  ) : null}
                </span>
              </Button>
            </li>
          ))}
        </ul>
        <DialogFooter>
          <DialogClose render={<Button type="button" variant="outline" />}>
            Cancel
          </DialogClose>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
