"use client";

import { useState } from "react";
import { Plus, Search } from "lucide-react";
import {
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import { SearchStandardReaderListsDialog } from "./SearchStandardReaderListsDialog";
import { StandardReaderListRow } from "./StandardReaderListRow";
import { AddStandardReaderListDialog } from "./AddStandardReaderListDialog";
import {
  CreateStandardReaderListDialog,
  type StandardReaderListCreator,
} from "./CreateStandardReaderListDialog";
import type { CreateStandardReaderListInput } from "@/lib/standardReaderList";
import type { StandardReaderListPublication } from "@/lib/standardReaderListsClient";
import type { StandardReaderList } from "@/lib/standardReaderListsClient";

export type SidebarListsSectionProps = {
  lists: StandardReaderList[];
  creatorResults: StandardReaderList[];
  selectedUri: string | null;
  loading: boolean;
  searching: boolean;
  saving: boolean;
  error?: string | null;
  onSelect: (uri: string) => void;
  onSearchCreator: (creator: string) => Promise<unknown>;
  onAdd: (input: string) => Promise<unknown>;
  onRemove: (uri: string) => Promise<unknown>;
  onRefresh: () => Promise<unknown>;
  publications?: StandardReaderListPublication[];
  onCreate?: (input: CreateStandardReaderListInput) => Promise<unknown>;
  onDelete?: (uri: string) => Promise<unknown>;
  onResolveCreator?: (input: string) => Promise<StandardReaderListCreator>;
};

const iconButtonClass =
  "flex size-8 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-sidebar-accent hover:text-sidebar-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring";
export function SidebarListsSection({
  lists,
  creatorResults,
  selectedUri,
  loading,
  searching,
  saving,
  error,
  onSelect,
  onSearchCreator,
  onAdd,
  onRemove,
  onRefresh,
  publications = [],
  onCreate,
  onDelete,
  onResolveCreator,
}: SidebarListsSectionProps) {
  const [searchOpen, setSearchOpen] = useState(false);
  const [addOpen, setAddOpen] = useState(false);
  const [createOpen, setCreateOpen] = useState(false);
  const [copyStatus, setCopyStatus] = useState<string | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const [confirmation, setConfirmation] = useState<{
    uri: string;
    kind: "remove" | "delete";
  } | null>(null);
  const run = async (action: () => Promise<unknown>) => {
    setLocalError(null);
    try {
      await action();
      return true;
    } catch (failure) {
      if (
        (failure as { originalDeleted?: boolean } | null)?.originalDeleted ===
        true
      )
        setConfirmation(null);
      setLocalError(
        failure instanceof Error
          ? failure.message
          : "Couldn't Update Lists. Try Again.",
      );
      return false;
    }
  };

  return (
    <SidebarGroup aria-label="Lists" className="pb-1">
      <div className="flex min-w-0 items-center pr-1">
        <SidebarGroupLabel className="min-w-0 flex-1">Lists</SidebarGroupLabel>
        <button
          type="button"
          aria-label="Search Lists"
          aria-expanded={searchOpen}
          className={iconButtonClass}
          onClick={() => setSearchOpen((open) => !open)}
        >
          <Search className="size-4" aria-hidden="true" />
        </button>
        <button
          type="button"
          aria-label="Add List"
          aria-expanded={addOpen}
          className={iconButtonClass}
          onClick={() => {
            setAddOpen(true);
          }}
        >
          <Plus className="size-4" aria-hidden="true" />
        </button>
      </div>
      <SearchStandardReaderListsDialog
        key={searchOpen ? "search-open" : "search-closed"}
        open={searchOpen}
        onOpenChange={setSearchOpen}
        lists={lists}
        loading={loading}
        error={localError || error}
        onSelect={onSelect}
      />
      <AddStandardReaderListDialog
        key={addOpen ? "open" : "closed"}
        open={addOpen}
        onOpenChange={setAddOpen}
        lists={lists}
        creatorResults={creatorResults}
        searching={searching}
        saving={saving}
        onSearchCreator={onSearchCreator}
        onAdd={onAdd}
        onCreate={
          onCreate && onResolveCreator ? () => setCreateOpen(true) : undefined
        }
      />
      {onCreate && onResolveCreator ? (
        <CreateStandardReaderListDialog
          key={createOpen ? "create-open" : "create-closed"}
          open={createOpen}
          onOpenChange={setCreateOpen}
          publications={publications}
          saving={saving}
          onCreate={onCreate}
          onResolveCreator={onResolveCreator}
        />
      ) : null}
      {copyStatus ? (
        <p role="status" className="px-2 pb-2 text-xs text-muted-foreground">
          {copyStatus}
        </p>
      ) : null}
      {localError || error ? (
        <div role="alert" className="px-2 pb-2 text-xs text-destructive">
          {localError || error}
          <button
            type="button"
            className="ml-1 underline"
            onClick={() => void run(onRefresh)}
          >
            Retry
          </button>
        </div>
      ) : null}
      <SidebarMenu className="gap-0.5">
        {loading && lists.length === 0 ? (
          <SidebarMenuItem
            role="status"
            className="px-2 py-2 text-xs text-muted-foreground"
          >
            Loading Lists…
          </SidebarMenuItem>
        ) : null}
        {!loading && !error && !localError && lists.length === 0 ? (
          <SidebarMenuItem className="px-2 py-2 text-xs text-muted-foreground">
            No Lists Yet.
          </SidebarMenuItem>
        ) : null}
        {lists.map((list) => (
          <StandardReaderListRow
            key={list.uri}
            list={list}
            selected={selectedUri === list.uri}
            saving={saving}
            onSelect={onSelect}
            onRequestRemove={(uri) => setConfirmation({ uri, kind: "remove" })}
            onRequestDelete={
              onDelete
                ? (uri) => setConfirmation({ uri, kind: "delete" })
                : undefined
            }
            onCopy={async (url) => {
              setCopyStatus(null);
              const success = await run(async () => {
                if (!navigator.clipboard?.writeText)
                  throw new Error("Couldn't Copy This Link. Try Again.");
                await navigator.clipboard.writeText(url);
              });
              if (success) setCopyStatus("List Link Copied.");
            }}
          />
        ))}
      </SidebarMenu>
      {confirmation ? (
        <div
          className="space-y-2 rounded-md border border-border p-2 text-xs"
          role="group"
          aria-label={
            confirmation.kind === "delete"
              ? "Confirm List Deletion"
              : "Confirm List Removal"
          }
        >
          <p>
            {confirmation.kind === "delete"
              ? "Delete your original public list and its saved references from your account? Copies and references held by others may remain."
              : "Remove this saved list? The original list stays available."}
          </p>
          <div className="flex gap-2">
            <button
              type="button"
              disabled={saving}
              className="min-h-8 text-destructive"
              onClick={() =>
                void run(() =>
                  confirmation.kind === "delete"
                    ? onDelete!(confirmation.uri)
                    : onRemove(confirmation.uri),
                ).then((success) => {
                  if (success) setConfirmation(null);
                })
              }
            >
              {confirmation.kind === "delete" ? "Delete List" : "Remove List"}
            </button>
            <button
              type="button"
              className="min-h-8"
              onClick={() => setConfirmation(null)}
            >
              Cancel
            </button>
          </div>
        </div>
      ) : null}
    </SidebarGroup>
  );
}
