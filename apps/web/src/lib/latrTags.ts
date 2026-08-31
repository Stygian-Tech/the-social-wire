import type { MergedLatrSave } from "@/lib/pdsClient";

export const LATR_TAG_PAGE_LIMIT = 25;

export function normalizeLatrTags(tags: readonly string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of tags) {
    const tag = raw.trim();
    if (!tag || seen.has(tag)) continue;
    seen.add(tag);
    result.push(tag);
  }
  return result;
}

export function parseLatrTagInput(value: string): string[] {
  return normalizeLatrTags(value.split(/[\n,]/));
}

export function filterLatrSavesByExactTag(
  rows: readonly MergedLatrSave[],
  tag: string | null | undefined
): MergedLatrSave[] {
  const exactTag = tag?.trim();
  if (!exactTag) return [...rows];
  return rows.filter((row) => row.tags?.includes(exactTag));
}

export function countLatrTags(
  rows: readonly MergedLatrSave[]
): Array<{ tag: string; count: number }> {
  const counts = new Map<string, number>();
  for (const row of rows) {
    for (const tag of row.tags ?? []) {
      counts.set(tag, (counts.get(tag) ?? 0) + 1);
    }
  }
  return [...counts.entries()]
    .map(([tag, count]) => ({ tag, count }))
    .sort((left, right) => left.tag < right.tag ? -1 : left.tag > right.tag ? 1 : 0);
}

export function replaceLatrTag(
  tags: readonly string[] | undefined,
  tag: string,
  replacement?: string
): string[] {
  return normalizeLatrTags(
    (tags ?? []).flatMap((candidate) => {
      if (candidate !== tag) return [candidate];
      return replacement?.trim() ? [replacement] : [];
    })
  );
}
