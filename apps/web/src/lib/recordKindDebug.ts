import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  parseAtUri,
  PUBLICATION_RECORD_COLLECTIONS,
} from "@/lib/atprotoClient";
import type { MergedLatrSave } from "@/lib/pdsClient";
import {
  isRssEntryId,
  isRssPublicationId,
  normalizedFeedUrlFromRssPublicationId,
} from "@/lib/rssFeedCore";

export type RecordSourceKind =
  | "standard.site"
  | "skyreader.app"
  | "L@tr.link"
  | "thesocialwire"
  | "bluesky"
  | "unknown";

export type RecordKindInfo = {
  source: RecordSourceKind;
  /** ATProto collection NSID or synthetic id kind when applicable. */
  collection?: string;
  /** Tooltip / screen-reader detail. */
  detail: string;
};

const STANDARD_SITE_COLLECTION_PREFIXES = [
  "site.standard.",
  "com.standard.",
] as const;

const LATR_COLLECTIONS = new Set([
  "com.latr.saved.external",
  "com.latr.saved.item",
]);

const SOCIALWIRE_COLLECTION_PREFIXES = [
  "app.thesocialwire.",
  "com.thesocialwire.",
] as const;

function isSocialWireCollection(collection: string): boolean {
  return SOCIALWIRE_COLLECTION_PREFIXES.some((prefix) =>
    collection.startsWith(prefix)
  );
}

const BSKY_COLLECTION_PREFIX = "app.bsky.";

function isStandardSiteCollection(collection: string): boolean {
  return STANDARD_SITE_COLLECTION_PREFIXES.some((prefix) =>
    collection.startsWith(prefix)
  );
}

function sourceForCollection(collection: string): RecordSourceKind {
  if (isStandardSiteCollection(collection)) return "standard.site";
  if (LATR_COLLECTIONS.has(collection)) return "L@tr.link";
  if (isSocialWireCollection(collection)) return "thesocialwire";
  if (collection.startsWith(BSKY_COLLECTION_PREFIX)) return "bluesky";
  return "unknown";
}

function kindFromAtUri(uri: string): RecordKindInfo | null {
  const parsed = parseAtUri(uri);
  if (!parsed) return null;
  const source = sourceForCollection(parsed.collection);
  return {
    source,
    collection: parsed.collection,
    detail: `${parsed.collection} · ${uri}`,
  };
}

/** Classify a sidebar publication row. */
export function recordKindFromPublication(
  publication: DiscoveredPublication
): RecordKindInfo {
  if (
    isRssPublicationId(publication.publicationId) ||
    publication.authorDid === "did:web:skyreader.rss"
  ) {
    const feedUrl =
      normalizedFeedUrlFromRssPublicationId(publication.publicationId) ??
      publication.title;
    return {
      source: "skyreader.app",
      collection: "app.skyreader.feed.subscription",
      detail: `RSS via Skyreader · ${feedUrl}`,
    };
  }

  for (const candidate of [
    publication.publicationId,
    publication.subscriptionPublicationId,
  ]) {
    if (!candidate) continue;
    const parsed = parseAtUri(candidate);
    if (parsed && PUBLICATION_RECORD_COLLECTIONS.has(parsed.collection)) {
      return {
        source: "standard.site",
        collection: parsed.collection,
        detail: `${parsed.collection} · ${candidate}`,
      };
    }
  }

  if (publication.publicationId.startsWith("did:")) {
    return {
      source: "standard.site",
      collection: "site.standard.graph.subscription",
      detail: `Author aggregate feed · ${publication.publicationId}`,
    };
  }

  const fromUri = kindFromAtUri(publication.publicationId);
  if (fromUri) return fromUri;

  return {
    source: "unknown",
    detail: publication.publicationId,
  };
}

/** Classify the active publication route key (`/read/[pubId]`). */
export function recordKindFromPubId(pubId: string): RecordKindInfo {
  if (isRssPublicationId(pubId)) {
    const feedUrl = normalizedFeedUrlFromRssPublicationId(pubId);
    return {
      source: "skyreader.app",
      collection: "app.skyreader.feed.subscription",
      detail: feedUrl ? `RSS via Skyreader · ${feedUrl}` : "RSS via Skyreader",
    };
  }

  const parsed = parseAtUri(pubId);
  if (parsed && PUBLICATION_RECORD_COLLECTIONS.has(parsed.collection)) {
    return {
      source: "standard.site",
      collection: parsed.collection,
      detail: `${parsed.collection} · ${pubId}`,
    };
  }

  if (pubId.startsWith("did:")) {
    return {
      source: "standard.site",
      collection: "site.standard.graph.subscription",
      detail: `Author aggregate feed · ${pubId}`,
    };
  }

  const fromUri = kindFromAtUri(pubId);
  if (fromUri) return fromUri;

  return { source: "unknown", detail: pubId };
}

/** Classify an entry/article id (AT-URI or synthetic RSS id). */
export function recordKindFromEntryId(entryId: string): RecordKindInfo {
  if (isRssEntryId(entryId)) {
    return {
      source: "skyreader.app",
      collection: "app.skyreader.feed.subscription",
      detail: `RSS item · ${entryId}`,
    };
  }

  const fromUri = kindFromAtUri(entryId);
  if (fromUri) return fromUri;

  return { source: "unknown", detail: entryId };
}

/** Classify a merged read-later row on `/saved`. */
export function recordKindFromLatrSave(row: MergedLatrSave): RecordKindInfo {
  if (row.kind === "external") {
    return {
      source: "L@tr.link",
      collection: "com.latr.saved.external",
      detail: `HTTPS wrapper + com.latr.saved.item · ${row.itemUri}`,
    };
  }

  const fromSubject = kindFromAtUri(row.subjectUri);
  if (fromSubject) {
    return {
      ...fromSubject,
      collection: "com.latr.saved.item",
      detail: `Native queue item · ${row.itemUri} → ${row.subjectUri}`,
    };
  }

  return {
    source: "L@tr.link",
    collection: "com.latr.saved.item",
    detail: row.itemUri,
  };
}
