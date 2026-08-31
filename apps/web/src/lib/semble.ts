export const SEMBLE_PROVIDER_ID = "semble" as const;
export const SEMBLE_PERMISSION_SCOPE = "include:network.cosmik.authFull";

export const SEMBLE_CARD_COLLECTION = "network.cosmik.card";
export const SEMBLE_COLLECTION_COLLECTION = "network.cosmik.collection";
export const SEMBLE_COLLECTION_LINK_COLLECTION =
  "network.cosmik.collectionLink";
export const SEMBLE_COLLECTION_LINK_REMOVAL_COLLECTION =
  "network.cosmik.collectionLinkRemoval";
export const SEMBLE_CONNECTION_COLLECTION = "network.cosmik.connection";

export type SembleProviderScope = {
  viewerDid: string;
  provider: typeof SEMBLE_PROVIDER_ID;
  collectionUri: string;
};

export type SembleCollection = {
  uri: string;
  name: string;
  description?: string;
  accessType?: "OPEN" | "CLOSED";
  cardCount: number;
  createdAt?: string;
  updatedAt?: string;
};

export type SembleContributor = {
  did: string;
  handle?: string;
  displayName?: string;
  avatar?: string;
};

export type SembleMembership = {
  linkUri?: string;
  linkCid?: string;
  authorDid: string;
  addedBy: string;
  addedAt?: string;
  viewerOwned: boolean;
};

export type SembleSavedItem = {
  id: string;
  cardUri: string;
  cardCid?: string;
  cardType: "URL" | "NOTE";
  url?: string;
  title?: string;
  description?: string;
  image?: string;
  siteName?: string;
  publishedAt?: string;
  createdAt?: string;
  membership?: SembleMembership;
  unlinkAvailable: boolean;
  contributor: SembleContributor;
  note?: {
    uri?: string;
    text: string;
    authorDid: string;
    editable: boolean;
  };
};

export type SembleConnection = {
  uri?: string;
  source: string;
  target: string;
  connectionType?: string;
  note?: string;
  createdAt?: string;
  updatedAt?: string;
  authorDid: string;
  editable: boolean;
};

export type SembleCollectionsPage = {
  collections: SembleCollection[];
  cursor?: string;
};

export type SembleCollectionPage = {
  collection: SembleCollection;
  items: SembleSavedItem[];
  cursor?: string;
  membershipComplete: boolean;
  recordLinksComplete: boolean;
};

export type SembleConnectionsPage = {
  connections: SembleConnection[];
  cursor?: string;
  recordLinksComplete: boolean;
};

export type ReadLaterProviderKey = "latr-gateway" | typeof SEMBLE_PROVIDER_ID;

export type ReadLaterCapabilities = {
  archive: boolean;
  tags: boolean;
  notes: boolean;
  connections: boolean;
  collectionMembership: boolean;
};

export function readLaterCapabilities(
  provider: ReadLaterProviderKey,
): ReadLaterCapabilities {
  return provider === SEMBLE_PROVIDER_ID
    ? {
        archive: false,
        tags: false,
        notes: true,
        connections: true,
        collectionMembership: true,
      }
    : {
        archive: true,
        tags: true,
        notes: false,
        connections: false,
        collectionMembership: false,
      };
}

export type ReadLaterSavedItem = {
  key: string;
  provider: ReadLaterProviderKey;
  collectionUri: string;
  url?: string;
  title?: string;
  description?: string;
  image?: string;
  siteName?: string;
  savedAt?: string;
  removable: boolean;
};

export function sembleSavedItemToReadLaterItem(
  collectionUri: string,
  item: SembleSavedItem,
): ReadLaterSavedItem {
  return {
    key: item.membership?.linkUri ?? item.id,
    provider: SEMBLE_PROVIDER_ID,
    collectionUri,
    ...(item.url ? { url: item.url } : {}),
    ...(item.title ? { title: item.title } : {}),
    ...(item.description ? { description: item.description } : {}),
    ...(item.image ? { image: item.image } : {}),
    ...(item.siteName ? { siteName: item.siteName } : {}),
    ...(item.membership?.addedAt || item.createdAt
      ? { savedAt: item.membership?.addedAt ?? item.createdAt }
      : {}),
    removable: item.unlinkAvailable,
  };
}

export const readLaterQueryKeys = {
  root: (viewerDid: string, provider: ReadLaterProviderKey) =>
    ["readLater", viewerDid, provider] as const,
  capabilities: (viewerDid: string, provider: ReadLaterProviderKey) =>
    [...readLaterQueryKeys.root(viewerDid, provider), "capabilities"] as const,
  collection: (
    viewerDid: string,
    provider: ReadLaterProviderKey,
    collectionUri: string,
  ) =>
    [
      ...readLaterQueryKeys.root(viewerDid, provider),
      "collection",
      collectionUri,
    ] as const,
  items: (
    viewerDid: string,
    provider: ReadLaterProviderKey,
    collectionUri: string,
  ) =>
    [
      ...readLaterQueryKeys.collection(viewerDid, provider, collectionUri),
      "items",
    ] as const,
  collections: (viewerDid: string) =>
    [...readLaterQueryKeys.root(viewerDid, SEMBLE_PROVIDER_ID), "collections"] as const,
  connections: (viewerDid: string, collectionUri: string, url: string) =>
    [
      ...readLaterQueryKeys.collection(
        viewerDid,
        SEMBLE_PROVIDER_ID,
        collectionUri,
      ),
      "connections",
      normalizeSembleUrl(url) ?? url.trim(),
    ] as const,
};

export function normalizeSembleUrl(value: string): string | null {
  const trimmed = value.trim();
  if (!trimmed) return null;
  try {
    const candidate = /^[a-z][a-z\d+.-]*:/i.test(trimmed)
      ? trimmed
      : `https://${trimmed}`;
    const url = new URL(candidate);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    url.protocol = "https:";
    url.hostname = url.hostname.toLowerCase();
    url.hash = "";
    if (url.port === "80" || url.port === "443") url.port = "";
    if (url.pathname === "/") url.pathname = "";
    return url.toString();
  } catch {
    return null;
  }
}

export function atUriOwnerDid(uri: string): string | null {
  const match = /^at:\/\/([^/]+)\/[^/]+\/[^/]+$/.exec(uri.trim());
  return match?.[1] ?? null;
}

export function normalizeSembleConnectionEndpoint(value: string): string | null {
  const trimmed = value.trim();
  if (/^at:\/\/[^/]+\/[^/]+\/[^/]+$/.test(trimmed)) return trimmed;
  return normalizeSembleUrl(trimmed);
}

function scopeAllowsAction(
  scope: string,
  collection: string,
  action: "create" | "update" | "delete",
): boolean {
  const [name, query = ""] = scope.split("?");
  if (name !== `repo:${collection}` && name !== "repo:*") return false;
  const actions = new URLSearchParams(query).getAll("action");
  return actions.length === 0 || actions.includes(action);
}

export function tokenScopesAllowSemble(scopeValue: unknown): boolean {
  const scopes = String(scopeValue ?? "")
    .split(/\s+/)
    .filter(Boolean);
  const collections = [
    SEMBLE_CARD_COLLECTION,
    SEMBLE_COLLECTION_COLLECTION,
    SEMBLE_COLLECTION_LINK_COLLECTION,
    SEMBLE_COLLECTION_LINK_REMOVAL_COLLECTION,
    SEMBLE_CONNECTION_COLLECTION,
  ];
  return collections.every((collection) =>
    (["create", "update", "delete"] as const).every((action) =>
      scopes.some((scope) => scopeAllowsAction(scope, collection, action)),
    ),
  );
}

export const SEMBLE_REAUTH_MESSAGE =
  "Semble access was added after this session began. Sign out and sign back in to grant access.";

export async function requireSembleScopes(session: {
  getTokenInfo(refresh: boolean | "auto"): Promise<{ scope?: unknown }>;
}): Promise<void> {
  const info = await session.getTokenInfo("auto");
  if (!tokenScopesAllowSemble(info.scope)) {
    throw new Error(SEMBLE_REAUTH_MESSAGE);
  }
}
