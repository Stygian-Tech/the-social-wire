import { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import {
  SEMBLE_CARD_COLLECTION,
  SEMBLE_COLLECTION_COLLECTION,
  SEMBLE_COLLECTION_LINK_COLLECTION,
  SEMBLE_COLLECTION_LINK_REMOVAL_COLLECTION,
  SEMBLE_CONNECTION_COLLECTION,
  atUriOwnerDid,
  normalizeSembleUrl,
  normalizeSembleConnectionEndpoint,
  requireSembleScopes,
} from "@/lib/semble";

export type SembleStrongRef = { uri: string; cid: string };

export type SembleUrlCardRecord = {
  $type: typeof SEMBLE_CARD_COLLECTION;
  type: "URL";
  content: {
    $type: "network.cosmik.card#urlContent";
    url: string;
    metadata?: Record<string, unknown>;
  };
  url?: string;
  createdAt: string;
};

export type SembleNoteCardRecord = {
  $type: typeof SEMBLE_CARD_COLLECTION;
  type: "NOTE";
  content: {
    $type: "network.cosmik.card#noteContent";
    text: string;
  };
  parentCard: SembleStrongRef;
  createdAt: string;
};

export type SembleCollectionRecord = {
  $type: typeof SEMBLE_COLLECTION_COLLECTION;
  name: string;
  accessType: "OPEN" | "CLOSED";
  description?: string;
  collaborators?: string[];
  createdAt?: string;
  updatedAt?: string;
};

export type SembleCollectionLinkRecord = {
  $type: typeof SEMBLE_COLLECTION_LINK_COLLECTION;
  collection: SembleStrongRef;
  card: SembleStrongRef;
  addedBy: string;
  addedAt: string;
  createdAt?: string;
};

export type SembleCollectionLinkRemovalRecord = {
  $type: typeof SEMBLE_COLLECTION_LINK_REMOVAL_COLLECTION;
  collection: SembleStrongRef;
  removedLink: SembleStrongRef;
  removedAt: string;
};

export type SembleConnectionRecord = {
  $type: typeof SEMBLE_CONNECTION_COLLECTION;
  source: string;
  target: string;
  connectionType: string;
  note?: string;
  createdAt: string;
  updatedAt?: string;
};

type RepoRecord<T> = {
  uri: string;
  cid: string;
  value: T;
};

function parseAtUri(uri: string): { did: string; collection: string; rkey: string } | null {
  const match = /^at:\/\/([^/]+)\/([^/]+)\/([^/]+)$/.exec(uri.trim());
  return match
    ? { did: match[1]!, collection: match[2]!, rkey: match[3]! }
    : null;
}

function cardUrl(record: SembleUrlCardRecord): string | null {
  return normalizeSembleUrl(record.content?.url || record.url || "");
}

export function sembleMembershipRemovalKind(
  viewerDid: string,
  linkUri: string | null | undefined,
): "delete-own-link" | "create-removal" | "unavailable" {
  if (!linkUri?.trim()) return "unavailable";
  return atUriOwnerDid(linkUri) === viewerDid
    ? "delete-own-link"
    : "create-removal";
}

export class SembleLinkCreationError extends Error {
  constructor(
    message: string,
    readonly orphanCard: SembleStrongRef,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = "SembleLinkCreationError";
  }
}

export class SemblePDSClient {
  private readonly agent: Agent;

  constructor(
    private readonly oauthSession: OAuthSession,
    readonly viewerDid: string,
  ) {
    this.agent = new Agent(oauthSession);
  }

  private async listRecords<T>(collection: string): Promise<RepoRecord<T>[]> {
    const records: RepoRecord<T>[] = [];
    let cursor: string | undefined;
    do {
      const response = await this.agent.api.com.atproto.repo.listRecords({
        repo: this.viewerDid,
        collection,
        limit: 100,
        cursor,
      });
      records.push(...(response.data.records as unknown as RepoRecord<T>[]));
      cursor = response.data.cursor?.trim() || undefined;
    } while (cursor);
    return records;
  }

  async getOwnedCollection(collectionUri: string): Promise<RepoRecord<SembleCollectionRecord>> {
    const parsed = parseAtUri(collectionUri);
    if (
      !parsed ||
      parsed.did !== this.viewerDid ||
      parsed.collection !== SEMBLE_COLLECTION_COLLECTION
    ) {
      throw new Error("Choose a Semble collection owned by this account.");
    }
    const response = await this.agent.api.com.atproto.repo.getRecord({
      repo: this.viewerDid,
      collection: SEMBLE_COLLECTION_COLLECTION,
      rkey: parsed.rkey,
    });
    return response.data as unknown as RepoRecord<SembleCollectionRecord>;
  }

  async ensureUrlCard(urlValue: string): Promise<{
    card: SembleStrongRef;
    normalizedUrl: string;
    created: boolean;
  }> {
    await requireSembleScopes(this.oauthSession);
    const normalizedUrl = normalizeSembleUrl(urlValue);
    if (!normalizedUrl) throw new Error("Enter a valid HTTP or HTTPS URL.");
    const existing = (await this.listRecords<SembleUrlCardRecord>(SEMBLE_CARD_COLLECTION))
      .find((record) => record.value.type === "URL" && cardUrl(record.value) === normalizedUrl);
    if (existing) {
      return {
        card: { uri: existing.uri, cid: existing.cid },
        normalizedUrl,
        created: false,
      };
    }
    const createdAt = new Date().toISOString();
    const response = await this.agent.api.com.atproto.repo.createRecord({
      repo: this.viewerDid,
      collection: SEMBLE_CARD_COLLECTION,
      record: {
        $type: SEMBLE_CARD_COLLECTION,
        type: "URL",
        content: {
          $type: "network.cosmik.card#urlContent",
          url: normalizedUrl,
        },
        url: normalizedUrl,
        createdAt,
      },
    });
    return {
      card: { uri: response.data.uri, cid: response.data.cid },
      normalizedUrl,
      created: true,
    };
  }

  private async findExistingLink(
    collectionUri: string,
    cardUri: string,
  ): Promise<RepoRecord<SembleCollectionLinkRecord> | undefined> {
    return (await this.listRecords<SembleCollectionLinkRecord>(SEMBLE_COLLECTION_LINK_COLLECTION))
      .find(
        (record) =>
          record.value.collection?.uri === collectionUri &&
          record.value.card?.uri === cardUri,
      );
  }

  async linkCardToCollection(
    collectionUri: string,
    card: SembleStrongRef,
  ): Promise<SembleStrongRef> {
    await requireSembleScopes(this.oauthSession);
    const collection = await this.getOwnedCollection(collectionUri);
    const existing = await this.findExistingLink(collection.uri, card.uri);
    if (existing) return { uri: existing.uri, cid: existing.cid };
    const addedAt = new Date().toISOString();
    const response = await this.agent.api.com.atproto.repo.createRecord({
      repo: this.viewerDid,
      collection: SEMBLE_COLLECTION_LINK_COLLECTION,
      record: {
        $type: SEMBLE_COLLECTION_LINK_COLLECTION,
        collection: { uri: collection.uri, cid: collection.cid },
        card,
        addedBy: this.viewerDid,
        addedAt,
        createdAt: addedAt,
      },
    });
    return { uri: response.data.uri, cid: response.data.cid };
  }

  async saveUrl(input: {
    collectionUri: string;
    url: string;
    note?: string;
  }): Promise<{
    card: SembleStrongRef;
    link: SembleStrongRef;
    note?: SembleStrongRef;
    normalizedUrl: string;
  }> {
    const ensured = await this.ensureUrlCard(input.url);
    let link: SembleStrongRef;
    try {
      link = await this.linkCardToCollection(input.collectionUri, ensured.card);
    } catch (cause) {
      throw new SembleLinkCreationError(
        ensured.created
          ? "The card was saved to Semble, but adding it to the collection failed. Retry the collection link."
          : "The existing Semble card could not be added to the collection. Retry the collection link.",
        ensured.card,
        { cause },
      );
    }
    const noteText = input.note?.trim();
    const note = noteText ? await this.createNote(ensured.card, noteText) : undefined;
    return {
      card: ensured.card,
      link,
      ...(note ? { note } : {}),
      normalizedUrl: ensured.normalizedUrl,
    };
  }

  async createNote(parentCard: SembleStrongRef, textValue: string): Promise<SembleStrongRef> {
    await requireSembleScopes(this.oauthSession);
    const text = textValue.trim();
    if (!text) throw new Error("Enter a note.");
    const response = await this.agent.api.com.atproto.repo.createRecord({
      repo: this.viewerDid,
      collection: SEMBLE_CARD_COLLECTION,
      record: {
        $type: SEMBLE_CARD_COLLECTION,
        type: "NOTE",
        content: {
          $type: "network.cosmik.card#noteContent",
          text,
        },
        parentCard,
        createdAt: new Date().toISOString(),
      },
    });
    return { uri: response.data.uri, cid: response.data.cid };
  }

  async updateOwnedNote(noteUri: string, textValue: string): Promise<void> {
    await requireSembleScopes(this.oauthSession);
    const parsed = parseAtUri(noteUri);
    const text = textValue.trim();
    if (
      !parsed ||
      parsed.did !== this.viewerDid ||
      parsed.collection !== SEMBLE_CARD_COLLECTION
    ) {
      throw new Error("Only notes owned by this account can be edited.");
    }
    if (!text) throw new Error("Enter a note.");
    const existing = await this.agent.api.com.atproto.repo.getRecord({
      repo: this.viewerDid,
      collection: SEMBLE_CARD_COLLECTION,
      rkey: parsed.rkey,
    });
    const record = existing.data.value as unknown as SembleNoteCardRecord;
    if (record.type !== "NOTE") throw new Error("The selected record is not a Semble note.");
    await this.agent.api.com.atproto.repo.putRecord({
      repo: this.viewerDid,
      collection: SEMBLE_CARD_COLLECTION,
      rkey: parsed.rkey,
      record: {
        ...record,
        content: {
          $type: "network.cosmik.card#noteContent",
          text,
        },
      },
    });
  }

  async createConnection(input: {
    source: string;
    target: string;
    connectionType: string;
    note?: string;
  }): Promise<SembleStrongRef> {
    await requireSembleScopes(this.oauthSession);
    const source = normalizeSembleConnectionEndpoint(input.source);
    const target = normalizeSembleConnectionEndpoint(input.target);
    if (!source || !target) {
      throw new Error("Connections require valid URLs or AT-URIs.");
    }
    const connectionType = input.connectionType.trim().toUpperCase();
    if (!connectionType) throw new Error("Choose a connection type.");
    const createdAt = new Date().toISOString();
    const response = await this.agent.api.com.atproto.repo.createRecord({
      repo: this.viewerDid,
      collection: SEMBLE_CONNECTION_COLLECTION,
      record: {
        $type: SEMBLE_CONNECTION_COLLECTION,
        source,
        target,
        connectionType,
        ...(input.note?.trim() ? { note: input.note.trim() } : {}),
        createdAt,
      },
    });
    return { uri: response.data.uri, cid: response.data.cid };
  }

  async updateOwnedConnection(input: {
    uri: string;
    target: string;
    connectionType: string;
    note?: string;
  }): Promise<void> {
    await requireSembleScopes(this.oauthSession);
    const parsed = parseAtUri(input.uri);
    if (
      !parsed ||
      parsed.did !== this.viewerDid ||
      parsed.collection !== SEMBLE_CONNECTION_COLLECTION
    ) {
      throw new Error("Only connections owned by this account can be edited.");
    }
    const target = normalizeSembleConnectionEndpoint(input.target);
    if (!target) throw new Error("Enter a valid target URL or AT-URI.");
    const existing = await this.agent.api.com.atproto.repo.getRecord({
      repo: this.viewerDid,
      collection: SEMBLE_CONNECTION_COLLECTION,
      rkey: parsed.rkey,
    });
    const record = existing.data.value as unknown as SembleConnectionRecord;
    const { note: _previousNote, ...recordWithoutNote } = record;
    void _previousNote;
    const connectionType = input.connectionType.trim().toUpperCase();
    if (!connectionType) throw new Error("Choose a connection type.");
    await this.agent.api.com.atproto.repo.putRecord({
      repo: this.viewerDid,
      collection: SEMBLE_CONNECTION_COLLECTION,
      rkey: parsed.rkey,
      record: {
        ...recordWithoutNote,
        target,
        connectionType,
        ...(input.note?.trim() ? { note: input.note.trim() } : {}),
        updatedAt: new Date().toISOString(),
      },
    });
  }

  async removeMembership(input: {
    collectionUri: string;
    linkUri: string;
    linkCid?: string;
  }): Promise<"deleted" | "removed"> {
    await requireSembleScopes(this.oauthSession);
    const parsed = parseAtUri(input.linkUri);
    if (
      sembleMembershipRemovalKind(this.viewerDid, input.linkUri) === "delete-own-link" &&
      parsed?.collection === SEMBLE_COLLECTION_LINK_COLLECTION
    ) {
      await this.agent.api.com.atproto.repo.deleteRecord({
        repo: this.viewerDid,
        collection: SEMBLE_COLLECTION_LINK_COLLECTION,
        rkey: parsed.rkey,
      });
      return "deleted";
    }
    if (!input.linkCid?.trim()) {
      throw new Error("This contributed collection link is still syncing. Try again shortly.");
    }
    const collection = await this.getOwnedCollection(input.collectionUri);
    await this.agent.api.com.atproto.repo.createRecord({
      repo: this.viewerDid,
      collection: SEMBLE_COLLECTION_LINK_REMOVAL_COLLECTION,
      record: {
        $type: SEMBLE_COLLECTION_LINK_REMOVAL_COLLECTION,
        collection: { uri: collection.uri, cid: collection.cid },
        removedLink: { uri: input.linkUri, cid: input.linkCid },
        removedAt: new Date().toISOString(),
      },
    });
    return "removed";
  }
}
