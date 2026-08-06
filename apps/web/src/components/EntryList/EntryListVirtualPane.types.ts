import type { EntryListItem } from "@/lib/atprotoClient";

export type EntryListVirtualPaneProps = {
  visibleEntries: EntryListItem[];
  selectedEntryId: string | null;
  /** Entry whose destination is being resolved from the PDS after a click. */
  resolvingEntryId?: string | null;
  onSelectEntry: (entryId: string, entry?: EntryListItem) => void;
  isEntryRead: (entryId: string) => boolean;
  readIndicatorsEnabled: boolean;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  isFetchNextPageError?: boolean;
  fetchNextPage: () => Promise<unknown>;
  scrollStateKey: string;
  publicationById: ReadonlyMap<
    string,
    { name: string; faviconUrl?: string }
  >;
  markEntryRead: (entryId: string) => void;
  markEntryUnread: (entryId: string) => void;
};
