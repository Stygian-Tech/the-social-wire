import { isOriginalEntryContentUri } from "@/lib/savedLinkSocialTarget";

export type ReadLaterSaveTarget =
  | {
      kind: "native";
      subjectUri: string;
      linkedWebUrl?: string;
      title?: string;
      excerpt?: string;
    }
  | {
      kind: "external";
      url: string;
      title?: string;
      excerpt?: string;
    };

/**
 * Prefer native `link.latr.saved.item` subjects for indexed ATProto entries
 * (standard.site documents/entries). Plain HTTPS saves stay external wrappers.
 */
export function resolveReadLaterSaveTarget(params: {
  entryId: string;
  url?: string;
  title?: string;
  excerpt?: string;
}): ReadLaterSaveTarget {
  const entryId = params.entryId.trim();
  const linkedWebUrl = params.url?.trim() || undefined;

  if (entryId && isOriginalEntryContentUri(entryId)) {
    return {
      kind: "native",
      subjectUri: entryId,
      linkedWebUrl,
      title: params.title,
      excerpt: params.excerpt,
    };
  }

  if (linkedWebUrl) {
    return {
      kind: "external",
      url: linkedWebUrl,
      title: params.title,
      excerpt: params.excerpt,
    };
  }

  return {
    kind: "native",
    subjectUri: entryId,
    title: params.title,
    excerpt: params.excerpt,
  };
}
