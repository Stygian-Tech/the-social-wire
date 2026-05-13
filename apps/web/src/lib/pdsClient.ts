/**
 * XRPC helper for reading and writing The Social Wire's ATProto records
 * directly on the user's PDS.
 *
 * Constructs a @atproto/api Agent from an OAuthSession (as documented at
 * https://github.com/bluesky-social/atproto/tree/main/packages/oauth/oauth-client-browser).
 * The agent handles DPoP signing and transparent token refresh.
 */

import { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";

// ── Lexicon collection IDs ────────────────────────────────────────────────────

export const COLLECTION_FOLDER = "com.thesocialwire.folder";
export const COLLECTION_PUB_PREFS = "com.thesocialwire.publicationPrefs";

/** Sidebar pseudo-folder URI (not a real `com.thesocialwire.folder` record). */
export const PSEUDO_FOLDER_MY_URI = "__my__";
export const PSEUDO_FOLDER_HIDDEN_URI = "__hidden__";

// ── Record types ──────────────────────────────────────────────────────────────

export interface FolderRecord {
  $type: typeof COLLECTION_FOLDER;
  name: string;
  sortOrder?: number;
  icon?: string;
  iconImage?: string;
  createdAt: string;
}

export interface PublicationPrefsRecord {
  $type: typeof COLLECTION_PUB_PREFS;
  publicationId: string;
  folderId?: string;
  sortOrder?: number;
  hidden?: boolean;
  createdAt: string;
}

export interface RepoRecord<T> {
  uri: string;
  cid: string;
  value: T;
}

// ── Client class ──────────────────────────────────────────────────────────────

export class PDSClient {
  private agent: Agent;
  private did: string;

  /**
   * @param oauthSession  The OAuthSession returned by BrowserOAuthClient.restore() / init()
   * @param did           The authenticated user's DID
   */
  constructor(oauthSession: OAuthSession, did: string) {
    // new Agent(oauthSession) is the officially documented pattern:
    // https://github.com/bluesky-social/atproto/tree/main/packages/oauth/oauth-client-browser
    this.agent = new Agent(oauthSession);
    this.did = did;
  }

  // ── Folders ──────────────────────────────────────────────────────────────

  async listFolders(): Promise<RepoRecord<FolderRecord>[]> {
    const response = await this.agent.api.com.atproto.repo.listRecords({
      repo: this.did,
      collection: COLLECTION_FOLDER,
      limit: 100,
    });
    return response.data.records as unknown as RepoRecord<FolderRecord>[];
  }

  async createFolder(
    name: string,
    options: { sortOrder?: number; icon?: string; iconImage?: string } = {}
  ): Promise<{ uri: string; cid: string }> {
    const record: FolderRecord = {
      $type: COLLECTION_FOLDER,
      name,
      sortOrder: options.sortOrder ?? 0,
      ...(options.icon ? { icon: options.icon } : {}),
      ...(options.iconImage ? { iconImage: options.iconImage } : {}),
      createdAt: new Date().toISOString(),
    };

    const response = await this.agent.api.com.atproto.repo.createRecord({
      repo: this.did,
      collection: COLLECTION_FOLDER,
      record: record as unknown as Record<string, unknown>,
    });

    return { uri: response.data.uri, cid: response.data.cid };
  }

  async updateFolder(
    rkey: string,
    updates: Partial<Pick<FolderRecord, "name" | "sortOrder" | "icon" | "iconImage">>
  ): Promise<void> {
    const current = await this.agent.api.com.atproto.repo.getRecord({
      repo: this.did,
      collection: COLLECTION_FOLDER,
      rkey,
    });

    const updated: FolderRecord = {
      ...(current.data.value as unknown as FolderRecord),
      ...updates,
    };

    await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_FOLDER,
      rkey,
      record: updated as unknown as Record<string, unknown>,
    });
  }

  async deleteFolder(rkey: string): Promise<void> {
    await this.agent.api.com.atproto.repo.deleteRecord({
      repo: this.did,
      collection: COLLECTION_FOLDER,
      rkey,
    });
  }

  // ── Publication prefs ─────────────────────────────────────────────────────

  async listPublicationPrefs(): Promise<RepoRecord<PublicationPrefsRecord>[]> {
    const all: RepoRecord<PublicationPrefsRecord>[] = [];
    let cursor: string | undefined;
    do {
      const response = await this.agent.api.com.atproto.repo.listRecords({
        repo: this.did,
        collection: COLLECTION_PUB_PREFS,
        limit: 100,
        cursor,
      });
      all.push(
        ...(response.data.records as unknown as RepoRecord<PublicationPrefsRecord>[])
      );
      cursor = response.data.cursor ?? undefined;
    } while (cursor);
    return all;
  }

  async upsertPublicationPrefs(
    publicationId: string,
    updates: Partial<Pick<PublicationPrefsRecord, "sortOrder" | "hidden">> & {
      folderId?: string | null;
    },
    existingRkey?: string
  ): Promise<{ uri: string; cid: string }> {
    const rkey = existingRkey ?? generateTID();

    let prev: PublicationPrefsRecord | null = null;
    if (existingRkey) {
      const current = await this.agent.api.com.atproto.repo.getRecord({
        repo: this.did,
        collection: COLLECTION_PUB_PREFS,
        rkey: existingRkey,
      });
      prev = current.data.value as unknown as PublicationPrefsRecord;
    }

    const sortOrder =
      updates.sortOrder !== undefined
        ? updates.sortOrder
        : (prev?.sortOrder ?? 0);
    const hidden =
      updates.hidden !== undefined ? updates.hidden : (prev?.hidden ?? false);

    let folderId: string | undefined;
    if ("folderId" in updates) {
      folderId = updates.folderId === null ? undefined : updates.folderId;
    } else {
      folderId = prev?.folderId;
    }

    const record: PublicationPrefsRecord = {
      $type: COLLECTION_PUB_PREFS,
      publicationId,
      sortOrder,
      hidden,
      createdAt: prev?.createdAt ?? new Date().toISOString(),
      ...(folderId !== undefined ? { folderId } : {}),
    };

    const response = await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_PUB_PREFS,
      rkey,
      record: record as unknown as Record<string, unknown>,
    });

    return { uri: response.data.uri, cid: response.data.cid };
  }

  async deletePublicationPrefs(rkey: string): Promise<void> {
    await this.agent.api.com.atproto.repo.deleteRecord({
      repo: this.did,
      collection: COLLECTION_PUB_PREFS,
      rkey,
    });
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Generates a TID (timestamp-based ID) suitable for use as an ATProto record key.
 * Format: base32(timestamp_microseconds || clock_id)
 */
function generateTID(): string {
  const ts = BigInt(Date.now()) * 1000n;
  const chars = "234567abcdefghijklmnopqrstuvwxyz";
  let n = ts;
  let result = "";
  for (let i = 0; i < 13; i++) {
    result = chars[Number(n & 31n)] + result;
    n >>= 5n;
  }
  return result;
}

/**
 * Extracts the rkey from an at-uri.
 * at://did:plc:xxx/com.thesocialwire.folder/rkey → "rkey"
 */
export function rkeyFromURI(uri: string): string {
  return uri.split("/").pop() ?? uri;
}
