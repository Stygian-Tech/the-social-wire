"use client";

import { Copy, List, MoreHorizontal, Trash2 } from "lucide-react";
import { SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { cn } from "@/lib/utils";
import {
  parseStandardReaderListUri,
  standardReaderListShareUrl,
} from "@/lib/standardReaderList";
import type { StandardReaderList } from "@/lib/standardReaderListsClient";

type Props = {
  list: StandardReaderList;
  selected: boolean;
  saving: boolean;
  onSelect: (uri: string) => void;
  onRequestRemove: (uri: string) => void;
  onRequestDelete?: (uri: string) => void;
  onCopy: (url: string) => Promise<unknown>;
};
export function StandardReaderListRow({
  list,
  selected,
  saving,
  onSelect,
  onRequestRemove,
  onRequestDelete,
  onCopy,
}: Props) {
  const rowClass = cn(
    "flex min-w-0 items-center rounded-lg",
    selected
      ? "bg-[var(--purple-surface)] text-[var(--purple-foreground)] [box-shadow:var(--purple-sidebar-selected)]"
      : "hover:bg-sidebar-accent/65 hover:text-sidebar-accent-foreground focus-within:bg-sidebar-accent/65 focus-within:text-sidebar-accent-foreground data-popup-open:bg-sidebar-accent/70 data-popup-open:text-sidebar-accent-foreground has-[[data-popup-open]]:bg-sidebar-accent/70 has-[[data-popup-open]]:text-sidebar-accent-foreground dark:hover:bg-sidebar-accent/48",
  );
  const button = (
    <SidebarMenuButton
      type="button"
      isActive={selected}
      aria-current={selected ? "page" : undefined}
      onClick={() => onSelect(list.uri)}
      tooltip={list.name}
      className="min-w-0 flex-1 bg-transparent text-inherit hover:bg-transparent hover:text-inherit focus-visible:bg-transparent active:bg-transparent data-open:bg-transparent data-active:bg-transparent data-active:text-inherit data-active:[box-shadow:none] data-active:hover:bg-transparent data-active:hover:text-inherit data-active:hover:[box-shadow:none] dark:hover:bg-transparent dark:data-active:hover:bg-transparent"
    >
      <List aria-hidden="true" />
      <span className="truncate">{list.name}</span>
    </SidebarMenuButton>
  );
  const shareURL = parseStandardReaderListUri(list.uri)
    ? standardReaderListShareUrl(list.uri)
    : null;
  return (
    <ContextMenu>
      <ContextMenuTrigger render={<SidebarMenuItem className={rowClass} />}>
        {button}
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <button
                type="button"
                aria-label={`More Actions For ${list.name}`}
                className="flex size-8 shrink-0 items-center justify-center rounded-md bg-transparent text-inherit hover:bg-transparent hover:text-inherit focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              />
            }
          >
            <MoreHorizontal aria-hidden="true" className="size-3.5" />
          </DropdownMenuTrigger>
          <DropdownMenuContent
            align="end"
            className="min-w-[11rem] max-w-(--available-width)"
          >
            <DropdownMenuItem
              className="whitespace-nowrap"
              disabled={!shareURL}
              onClick={() => {
                if (shareURL) void onCopy(shareURL);
              }}
            >
              <Copy aria-hidden="true" className="size-4" />
              Copy Link
            </DropdownMenuItem>
            {list.saved && !list.owned ? (
              <DropdownMenuItem
                variant="destructive"
                className="whitespace-nowrap"
                disabled={saving}
                onClick={() => onRequestRemove(list.uri)}
              >
                <Trash2 aria-hidden="true" className="size-4" />
                Remove List
              </DropdownMenuItem>
            ) : null}
            {list.owned && onRequestDelete ? (
              <DropdownMenuItem
                variant="destructive"
                className="whitespace-nowrap"
                disabled={saving}
                onClick={() => onRequestDelete(list.uri)}
              >
                <Trash2 aria-hidden="true" className="size-4" />
                Delete List
              </DropdownMenuItem>
            ) : null}
          </DropdownMenuContent>
        </DropdownMenu>
      </ContextMenuTrigger>
      <ContextMenuContent className="min-w-[11rem] max-w-(--available-width)">
        <ContextMenuItem
          className="whitespace-nowrap"
          disabled={!shareURL}
          onClick={() => {
            if (shareURL) void onCopy(shareURL);
          }}
        >
          <Copy aria-hidden="true" className="size-4" />
          Copy Link
        </ContextMenuItem>
        {list.saved && !list.owned ? (
          <ContextMenuItem
            variant="destructive"
            className="whitespace-nowrap"
            disabled={saving}
            onClick={() => onRequestRemove(list.uri)}
          >
            <Trash2 aria-hidden="true" className="size-4" />
            Remove List
          </ContextMenuItem>
        ) : null}
        {list.owned && onRequestDelete ? (
          <ContextMenuItem
            variant="destructive"
            className="whitespace-nowrap"
            disabled={saving}
            onClick={() => onRequestDelete(list.uri)}
          >
            <Trash2 aria-hidden="true" className="size-4" />
            Delete List
          </ContextMenuItem>
        ) : null}
      </ContextMenuContent>
    </ContextMenu>
  );
}
