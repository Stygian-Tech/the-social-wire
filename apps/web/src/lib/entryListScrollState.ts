const MAX_SAVED_FEEDS = 24;
const scrollOffsets = new Map<string, number>();

export function loadEntryListScrollOffset(key: string): number {
  return scrollOffsets.get(key) ?? 0;
}

export function saveEntryListScrollOffset(key: string, offset: number): void {
  scrollOffsets.delete(key);
  scrollOffsets.set(key, Math.max(0, offset));
  while (scrollOffsets.size > MAX_SAVED_FEEDS) {
    const oldest = scrollOffsets.keys().next().value;
    if (oldest == null) break;
    scrollOffsets.delete(oldest);
  }
}

export function clearEntryListScrollOffsetsForTests(): void {
  scrollOffsets.clear();
}
