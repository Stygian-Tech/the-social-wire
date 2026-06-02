import {
  COLLECTION_SAVED_EXTERNAL,
  COLLECTION_SAVED_ITEM,
  isLatrExternalWrapperCollection,
  LEGACY_COLLECTION_SAVED_EXTERNAL,
  LEGACY_COLLECTION_SAVED_ITEM,
  LATR_REPO_OAUTH_SCOPES,
  remapLegacyLatrSubjectUri,
} from "latr-packages/gateway-client";

export {
  COLLECTION_SAVED_EXTERNAL,
  COLLECTION_SAVED_ITEM,
  isLatrExternalWrapperCollection,
  LEGACY_COLLECTION_SAVED_EXTERNAL,
  LEGACY_COLLECTION_SAVED_ITEM,
  LATR_REPO_OAUTH_SCOPES,
  remapLegacyLatrSubjectUri,
};

/** Canonical L@tr read-later collections (post domain migration). */
export const COLLECTION_LATR_SAVED_EXTERNAL = COLLECTION_SAVED_EXTERNAL;
export const COLLECTION_LATR_SAVED_ITEM = COLLECTION_SAVED_ITEM;
export const LEGACY_COLLECTION_LATR_SAVED_EXTERNAL = LEGACY_COLLECTION_SAVED_EXTERNAL;
export const LEGACY_COLLECTION_LATR_SAVED_ITEM = LEGACY_COLLECTION_SAVED_ITEM;

const LATR_SAVED_ITEM_COLLECTIONS = [
  COLLECTION_LATR_SAVED_ITEM,
  LEGACY_COLLECTION_LATR_SAVED_ITEM,
] as const;

export function isLatrSavedItemCollection(collection: string): boolean {
  return (LATR_SAVED_ITEM_COLLECTIONS as readonly string[]).includes(collection);
}

export function isLatrExternalSubjectUri(subjectUri: string): boolean {
  const parsed = parseLatrExternalSubject(subjectUri);
  return parsed !== null;
}

export function parseLatrExternalSubject(
  subjectUri: string
): { collection: string; externalRkey: string } | null {
  for (const collection of [
    COLLECTION_LATR_SAVED_EXTERNAL,
    LEGACY_COLLECTION_LATR_SAVED_EXTERNAL,
  ]) {
    const marker = `/${collection}/`;
    const index = subjectUri.indexOf(marker);
    if (index >= 0) {
      return {
        collection,
        externalRkey: subjectUri.slice(index + marker.length),
      };
    }
  }
  return null;
}

export function normalizeLatrSubjectUri(
  subjectUri: string,
  repositoryDid: string
): string {
  return remapLegacyLatrSubjectUri(subjectUri, repositoryDid);
}
