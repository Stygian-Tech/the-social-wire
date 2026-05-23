import type { EntryListItem } from "@/lib/atprotoClient";

export type EntryListVirtualPaneProps = {
  visibleEntries: EntryListItem[];
  selectedEntryId: string | null;
  onSelectEntry: (entryId: string) => void;
  isEntryRead: (entryId: string) => boolean;
  readIndicatorsEnabled: boolean;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  isFetchNextPageError?: boolean;
  fetchNextPage: () => void;
  markEntryRead: (entryId: string) => void;
  markEntryUnread: (entryId: string) => void;
};
