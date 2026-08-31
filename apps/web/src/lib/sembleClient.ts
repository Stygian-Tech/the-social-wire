import type { OAuthSession } from "@atproto/oauth-client-browser";

import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import type {
  SembleCollection,
  SembleCollectionPage,
  SembleCollectionsPage,
  SembleConnection,
  SembleConnectionsPage,
  SembleSavedItem,
} from "@/lib/semble";

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : {};
}

function normalizeCollection(value: unknown): SembleCollection | null {
  const raw = objectValue(value);
  const uri = stringValue(raw.uri);
  const name = stringValue(raw.name);
  if (!uri || !name) return null;
  const accessType = raw.accessType === "OPEN" || raw.accessType === "CLOSED"
    ? raw.accessType
    : undefined;
  return {
    uri,
    name,
    ...(stringValue(raw.description)
      ? { description: stringValue(raw.description) }
      : {}),
    ...(accessType ? { accessType } : {}),
    cardCount:
      typeof raw.cardCount === "number" && Number.isFinite(raw.cardCount)
        ? Math.max(0, raw.cardCount)
        : 0,
    ...(stringValue(raw.createdAt) ? { createdAt: stringValue(raw.createdAt) } : {}),
    ...(stringValue(raw.updatedAt) ? { updatedAt: stringValue(raw.updatedAt) } : {}),
  };
}

function normalizeSavedItem(value: unknown): SembleSavedItem | null {
  const raw = objectValue(value);
  const membership = objectValue(raw.membership);
  const contributor = objectValue(raw.contributor);
  const note = objectValue(raw.note);
  const id = stringValue(raw.id);
  const cardUri = stringValue(raw.cardUri);
  const linkUri = stringValue(membership.linkUri);
  const membershipAuthorDid = stringValue(membership.authorDid);
  const addedBy = stringValue(membership.addedBy);
  const contributorDid = stringValue(contributor.did);
  const cardType = raw.cardType === "NOTE" ? "NOTE" : raw.cardType === "URL" ? "URL" : null;
  if (
    !id ||
    !cardUri ||
    !cardType ||
    !contributorDid
  ) {
    return null;
  }
  const noteUri = stringValue(note.uri);
  const noteText = stringValue(note.text);
  const noteAuthorDid = stringValue(note.authorDid);
  return {
    id,
    cardUri,
    ...(stringValue(raw.cardCid) ? { cardCid: stringValue(raw.cardCid) } : {}),
    cardType,
    ...(stringValue(raw.url) ? { url: stringValue(raw.url) } : {}),
    ...(stringValue(raw.title) ? { title: stringValue(raw.title) } : {}),
    ...(stringValue(raw.description)
      ? { description: stringValue(raw.description) }
      : {}),
    ...(stringValue(raw.image) ? { image: stringValue(raw.image) } : {}),
    ...(stringValue(raw.siteName) ? { siteName: stringValue(raw.siteName) } : {}),
    ...(stringValue(raw.publishedAt)
      ? { publishedAt: stringValue(raw.publishedAt) }
      : {}),
    ...(stringValue(raw.createdAt) ? { createdAt: stringValue(raw.createdAt) } : {}),
    ...(membershipAuthorDid && addedBy
      ? {
          membership: {
            ...(linkUri ? { linkUri } : {}),
            ...(stringValue(membership.linkCid)
              ? { linkCid: stringValue(membership.linkCid) }
              : {}),
            authorDid: membershipAuthorDid,
            addedBy,
            ...(stringValue(membership.addedAt)
              ? { addedAt: stringValue(membership.addedAt) }
              : {}),
            viewerOwned: membership.viewerOwned === true,
          },
        }
      : {}),
    unlinkAvailable: raw.unlinkAvailable === true,
    contributor: {
      did: contributorDid,
      ...(stringValue(contributor.handle)
        ? { handle: stringValue(contributor.handle) }
        : {}),
      ...(stringValue(contributor.displayName)
        ? { displayName: stringValue(contributor.displayName) }
        : {}),
      ...(stringValue(contributor.avatar)
        ? { avatar: stringValue(contributor.avatar) }
        : {}),
    },
    ...(noteText && noteAuthorDid
      ? {
          note: {
            ...(noteUri ? { uri: noteUri } : {}),
            text: noteText,
            authorDid: noteAuthorDid,
            editable: note.editable === true,
          },
        }
      : {}),
  };
}

function normalizeConnection(value: unknown): SembleConnection | null {
  const raw = objectValue(value);
  const uri = stringValue(raw.uri);
  const source = stringValue(raw.source);
  const target = stringValue(raw.target);
  const authorDid = stringValue(raw.authorDid);
  if (!source || !target || !authorDid) return null;
  return {
    ...(uri ? { uri } : {}),
    source,
    target,
    ...(stringValue(raw.connectionType)
      ? { connectionType: stringValue(raw.connectionType) }
      : {}),
    ...(stringValue(raw.note) ? { note: stringValue(raw.note) } : {}),
    ...(stringValue(raw.createdAt) ? { createdAt: stringValue(raw.createdAt) } : {}),
    ...(stringValue(raw.updatedAt) ? { updatedAt: stringValue(raw.updatedAt) } : {}),
    authorDid,
    editable: raw.editable === true,
  };
}

export class SembleReadError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly retryable: boolean,
  ) {
    super(message);
    this.name = "SembleReadError";
  }
}

async function responseError(response: Response, fallback: string): Promise<Error> {
  try {
    const body = (await response.json()) as {
      message?: string;
      error?: string;
      retryable?: boolean;
    };
    return new SembleReadError(
      stringValue(body.message) ||
        stringValue(body.error) ||
        `${fallback} (${response.status})`,
      response.status,
      body.retryable === true,
    );
  } catch {
    return new SembleReadError(
      `${fallback} (${response.status})`,
      response.status,
      response.status >= 500,
    );
  }
}

export function normalizeSembleCollectionsPage(value: unknown): SembleCollectionsPage {
  const raw = objectValue(value);
  const values = Array.isArray(raw.collections) ? raw.collections : [];
  return {
    collections: values
      .map(normalizeCollection)
      .filter((collection): collection is SembleCollection => collection !== null),
    ...(stringValue(raw.cursor) ? { cursor: stringValue(raw.cursor) } : {}),
  };
}

export function normalizeSembleCollectionPage(value: unknown): SembleCollectionPage {
  const raw = objectValue(value);
  const collection = normalizeCollection(raw.collection);
  if (!collection) throw new Error("Semble returned an invalid collection.");
  const values = Array.isArray(raw.items) ? raw.items : [];
  return {
    collection,
    items: values
      .map(normalizeSavedItem)
      .filter((item): item is SembleSavedItem => item !== null),
    ...(stringValue(raw.cursor) ? { cursor: stringValue(raw.cursor) } : {}),
    membershipComplete: raw.membershipComplete === true,
    recordLinksComplete: raw.recordLinksComplete === true,
  };
}

export function normalizeSembleConnectionsPage(value: unknown): SembleConnectionsPage {
  const raw = objectValue(value);
  const values = Array.isArray(raw.connections) ? raw.connections : [];
  return {
    connections: values
      .map(normalizeConnection)
      .filter((connection): connection is SembleConnection => connection !== null),
    ...(stringValue(raw.cursor) ? { cursor: stringValue(raw.cursor) } : {}),
    recordLinksComplete: raw.recordLinksComplete === true,
  };
}

export class SembleReadClient {
  constructor(private readonly oauthSession: OAuthSession) {}

  async listCollections(input: {
    cursor?: string;
    limit?: number;
    signal?: AbortSignal;
  } = {}): Promise<SembleCollectionsPage> {
    const query = new URLSearchParams({ limit: String(input.limit ?? 100) });
    if (input.cursor) query.set("cursor", input.cursor);
    const response = await gatewayFetch(
      this.oauthSession,
      `/v1/semble/collections?${query.toString()}`,
      { method: "GET", signal: input.signal },
    );
    if (!response.ok) {
      throw await responseError(response, "Semble collections failed");
    }
    return normalizeSembleCollectionsPage(await response.json());
  }

  async getCollection(input: {
    collectionUri: string;
    cursor?: string;
    limit?: number;
    signal?: AbortSignal;
  }): Promise<SembleCollectionPage> {
    const query = new URLSearchParams({
      collectionUri: input.collectionUri,
      limit: String(input.limit ?? 100),
    });
    if (input.cursor) query.set("cursor", input.cursor);
    const response = await gatewayFetch(
      this.oauthSession,
      `/v1/semble/collection?${query.toString()}`,
      { method: "GET", signal: input.signal },
    );
    if (!response.ok) {
      throw await responseError(response, "Semble collection failed");
    }
    return normalizeSembleCollectionPage(await response.json());
  }

  async listConnections(input: {
    url: string;
    cursor?: string;
    limit?: number;
    signal?: AbortSignal;
  }): Promise<SembleConnectionsPage> {
    const query = new URLSearchParams({
      url: input.url,
      limit: String(input.limit ?? 100),
    });
    if (input.cursor) query.set("cursor", input.cursor);
    const response = await gatewayFetch(
      this.oauthSession,
      `/v1/semble/connections?${query.toString()}`,
      { method: "GET", signal: input.signal },
    );
    if (!response.ok) {
      throw await responseError(response, "Semble connections failed");
    }
    return normalizeSembleConnectionsPage(await response.json());
  }
}
