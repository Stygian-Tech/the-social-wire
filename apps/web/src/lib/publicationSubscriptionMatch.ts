import {
  normalizeAtRepoParam,
  parseAtUri,
  PUBLICATION_RECORD_COLLECTIONS,
  type DiscoveredPublication,
} from "@/lib/atprotoClient";

/**
 * Value suitable for `PDSClient.createPublicationSubscription`: a publication AT-URI or author DID,
 * derived from a followed-account discovery row.
 */
export function standardSiteSubscriptionTargetFromDiscovery(
  pub: DiscoveredPublication
): string | null {
  const candidates = [pub.subscriptionPublicationId, pub.publicationId];
  for (const raw of candidates) {
    const t = raw?.trim();
    if (!t) continue;
    const n = normalizeAtRepoParam(t);
    if (n.startsWith("at://")) {
      const p = parseAtUri(n);
      if (p && PUBLICATION_RECORD_COLLECTIONS.has(p.collection)) return n;
      continue;
    }
    if (n.startsWith("did:")) return n;
  }
  return null;
}

export function addPublicationSubscriptionLookupKeys(
  keys: Set<string>,
  value: string | undefined
) {
  if (!value) return;
  const normalized = normalizeAtRepoParam(value);

  if (normalized.startsWith("did:")) {
    keys.add(normalized);
    return;
  }

  const parsed = parseAtUri(normalized);
  if (!parsed) return;

  keys.add(normalized);
  keys.add(parsed.did);
  if (parsed.collection === "site.standard.publication") {
    keys.add(`at://${parsed.did}/com.standard.publication/${parsed.rkey}`);
  } else if (parsed.collection === "com.standard.publication") {
    keys.add(`at://${parsed.did}/site.standard.publication/${parsed.rkey}`);
  }
}

/** Keys used to match a discovered publication against `site.standard.graph.subscription.publication`. */
export function publicationSubscriptionMatchKeys(pub: DiscoveredPublication): string[] {
  const keys = new Set<string>();
  addPublicationSubscriptionLookupKeys(keys, pub.subscriptionPublicationId);
  addPublicationSubscriptionLookupKeys(keys, pub.publicationId);
  return [...keys];
}
