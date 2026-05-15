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

import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
import {
  resolveNativeSavedSubjectPreview,
  type NativeSavedSubjectPreview,
  parseAtUri,
  PUBLICATION_RECORD_COLLECTIONS,
} from "@/lib/atprotoClient";
import {
  latrExternalRkeyFromNormalizedUrl,
  latrFingerprintFromNormalizedUrl,
  latrItemRkeyFromSubjectUri,
  normalizeLatrHttpsUrl,
} from "@/lib/latrSavedUrls";

// ── Lexicon collection IDs ────────────────────────────────────────────────────

export const COLLECTION_FOLDER = "com.thesocialwire.folder";
export const COLLECTION_PUB_PREFS = "com.thesocialwire.publicationPrefs";
export const COLLECTION_PREFERENCES = "com.thesocialwire.preferences";
export const COLLECTION_STANDARD_SITE_SUBSCRIPTION =
  "site.standard.graph.subscription";
/** Skyreader RSS/Atom subscriptions (writes require OAuth repo scope). */
export const COLLECTION_SKYREADER_FEED_SUBSCRIPTION =
  "app.skyreader.feed.subscription";
export const COLLECTION_LATR_SAVED_EXTERNAL = "com.latr.saved.external";
export const COLLECTION_LATR_SAVED_ITEM = "com.latr.saved.item";
export const PREFERENCES_RKEY = "self";

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

export interface PublicationSubscriptionRecord {
  $type: typeof COLLECTION_STANDARD_SITE_SUBSCRIPTION;
  publication: string;
}

export interface SkyreaderFeedSubscriptionRecord {
  $type: typeof COLLECTION_SKYREADER_FEED_SUBSCRIPTION;
  createdAt: string;
  updatedAt?: string;
  feedUrl?: string;
  title?: string;
  siteUrl?: string;
  category?: string;
  tags?: string[];
  source?: string;
  sourceType?: string;
  subjectDid?: string;
  collectionNsid?: string;
  customTitle?: string;
  customIconUrl?: string;
  externalRef?: string;
}

export type ReadLaterServicePreference =
  | "latr-link"
  | "instapaper"
  | "omnivore"
  | "readwise-reader"
  | "raindrop";

export interface ReadLaterConnectionPreference {
  connectedAt?: string;
  accountLabel?: string;
}

export interface PreferencesRecord {
  $type: typeof COLLECTION_PREFERENCES;
  readLaterService?: ReadLaterServicePreference;
  readLaterConnections?: Partial<
    Record<
      Exclude<ReadLaterServicePreference, "latr-link">,
      ReadLaterConnectionPreference
    >
  >;
  createdAt: string;
  updatedAt: string;
}

export interface LatrSavedExternalRecord {
  $type: typeof COLLECTION_LATR_SAVED_EXTERNAL;
  url: string;
  normalizedUrl: string;
  fingerprint: string;
  createdAt: string;
  title?: string;
  excerpt?: string;
  site?: string;
  image?: string;
  language?: string;
  publishedAt?: string;
  author?: string;
}

export interface LatrSavedItemRecord {
  $type: typeof COLLECTION_LATR_SAVED_ITEM;
  subjectUri: string;
  savedAt: string;
  state?: "unread" | "archived";
  tags?: string[];
  note?: string;
  lastOpenedAt?: string;
}

export type MergedLatrSave =
  | {
      kind: "external";
      normalizedUrl: string;
      /** Original URL preserved on wrapper (typically HTTPS-promoted). */
      url: string;
      savedAt: string;
      externalRkey: string;
      itemRkey: string;
      externalUri: string;
      itemUri: string;
      subjectUri: string;
      state?: "unread" | "archived";
      title?: string;
      excerpt?: string;
      image?: string;
    }
  | {
      kind: "native";
      savedAt: string;
      itemRkey: string;
      itemUri: string;
      subjectUri: string;
      state?: "unread" | "archived";
      title?: string;
      excerpt?: string;
      url?: string;
      image?: string;
    };

export interface MergedLatrHttpsSave {
  kind: "external";
  normalizedUrl: string;
  /** Original URL preserved on wrapper (typically HTTPS-promoted). */
  url: string;
  savedAt: string;
  externalRkey: string;
  itemRkey: string;
  externalUri: string;
  itemUri: string;
  subjectUri: string;
  state?: "unread" | "archived";
  title?: string;
  excerpt?: string;
  image?: string;
}

export interface RepoRecord<T> {
  uri: string;
  cid: string;
  value: T;
}

const LATR_EXTERNAL_SUBJECT_MARKER = `/${COLLECTION_LATR_SAVED_EXTERNAL}/`;

/**
 * Pairs queue items with HTTPS external wrappers and keeps native ATProto subjects as rows.
 */
export function mergeExternalsAndItemsToHttpsRows(
  externals: RepoRecord<LatrSavedExternalRecord>[],
  items: RepoRecord<LatrSavedItemRecord>[]
): MergedLatrSave[] {
  const externalsByRkey = new Map(
    externals.map((rec) => [rkeyFromURI(rec.uri), rec] as const)
  );

  const rows: MergedLatrSave[] = [];

  for (const itemRec of items) {
    const { subjectUri, savedAt } = itemRec.value;
    const m = subjectUri.indexOf(LATR_EXTERNAL_SUBJECT_MARKER);
    if (m < 0) {
      rows.push({
        kind: "native",
        savedAt,
        itemRkey: rkeyFromURI(itemRec.uri),
        itemUri: itemRec.uri,
        subjectUri,
        ...(itemRec.value.state ? { state: itemRec.value.state } : {}),
      });
      continue;
    }
    const externalRkey = subjectUri.slice(m + LATR_EXTERNAL_SUBJECT_MARKER.length);

    const ext = externalsByRkey.get(externalRkey);
    if (!ext) continue;

    rows.push({
      kind: "external",
      normalizedUrl: ext.value.normalizedUrl,
      url: ext.value.url,
      savedAt,
      externalRkey: rkeyFromURI(ext.uri),
      itemRkey: rkeyFromURI(itemRec.uri),
      externalUri: ext.uri,
      itemUri: itemRec.uri,
      subjectUri,
      ...(itemRec.value.state ? { state: itemRec.value.state } : {}),
      title: ext.value.title,
      excerpt: ext.value.excerpt,
      image: ext.value.image,
    });
  }

  rows.sort((a, b) => {
    const ta = Date.parse(a.savedAt);
    const tb = Date.parse(b.savedAt);
    return (Number.isNaN(tb) ? 0 : tb) - (Number.isNaN(ta) ? 0 : ta);
  });

  const seen = new Set<string>();
  const deduped: MergedLatrSave[] = [];
  for (const row of rows) {
    const k =
      row.kind === "external"
        ? `external:${row.normalizedUrl.toLowerCase()}`
        : `native:${row.subjectUri}`;
    if (seen.has(k)) continue;
    seen.add(k);
    deduped.push(row);
  }

  return deduped;
}

// ── Client class ──────────────────────────────────────────────────────────────

export class PDSClient {
  private agent: Agent;
  private did: string;
  private oauthSession: OAuthSession;

  /**
   * @param oauthSession  The OAuthSession returned by BrowserOAuthClient.restore() / init()
   * @param did           The authenticated user's DID
   */
  constructor(oauthSession: OAuthSession, did: string) {
    // new Agent(oauthSession) is the officially documented pattern:
    // https://github.com/bluesky-social/atproto/tree/main/packages/oauth/oauth-client-browser
    this.agent = new Agent(oauthSession);
    this.did = did;
    this.oauthSession = oauthSession;
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

  async listPublicationSubscriptions(): Promise<
    RepoRecord<PublicationSubscriptionRecord>[]
  > {
    const all: RepoRecord<PublicationSubscriptionRecord>[] = [];
    let cursor: string | undefined;
    do {
      const response = await this.agent.api.com.atproto.repo.listRecords({
        repo: this.did,
        collection: COLLECTION_STANDARD_SITE_SUBSCRIPTION,
        limit: 100,
        cursor,
      });
      all.push(
        ...(response.data.records as unknown as RepoRecord<PublicationSubscriptionRecord>[])
      );
      cursor = response.data.cursor ?? undefined;
    } while (cursor);
    return all;
  }

  /**
   * Subscribe to a standard.site publication via `site.standard.graph.subscription`
   * (`publication`: AT-URI or bare author DID).
   */
  async createPublicationSubscription(input: {
    publication: string;
  }): Promise<{ uri: string; cid: string }> {
    const publication = input.publication.trim();
    if (!publication) throw new Error("Missing publication");

    if (publication.startsWith("at://")) {
      const parsed = parseAtUri(publication);
      if (!parsed || !PUBLICATION_RECORD_COLLECTIONS.has(parsed.collection)) {
        throw new Error(
          "Publication must be a site.standard.publication or com.standard.publication AT-URI"
        );
      }
    } else if (!publication.startsWith("did:")) {
      throw new Error("Publication must be an AT-URI or author DID");
    }

    const record: PublicationSubscriptionRecord = {
      $type: COLLECTION_STANDARD_SITE_SUBSCRIPTION,
      publication,
    };
    const response = await this.agent.api.com.atproto.repo.createRecord({
      repo: this.did,
      collection: COLLECTION_STANDARD_SITE_SUBSCRIPTION,
      record: record as unknown as Record<string, unknown>,
    });
    return { uri: response.data.uri, cid: response.data.cid };
  }

  async deletePublicationSubscription(rkey: string): Promise<void> {
    await this.agent.api.com.atproto.repo.deleteRecord({
      repo: this.did,
      collection: COLLECTION_STANDARD_SITE_SUBSCRIPTION,
      rkey,
    });
  }

  async listSkyreaderFeedSubscriptions(): Promise<
    RepoRecord<SkyreaderFeedSubscriptionRecord>[]
  > {
    const all: RepoRecord<SkyreaderFeedSubscriptionRecord>[] = [];
    let cursor: string | undefined;
    do {
      const response = await this.agent.api.com.atproto.repo.listRecords({
        repo: this.did,
        collection: COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
        limit: 100,
        cursor,
      });
      all.push(
        ...(response.data.records as unknown as RepoRecord<SkyreaderFeedSubscriptionRecord>[])
      );
      cursor = response.data.cursor ?? undefined;
    } while (cursor);
    return all;
  }

  /**
   * Creates a TID-keyed Skyreader feed subscription (`app.skyreader.feed.subscription`).
   */
  async createSkyreaderFeedSubscription(input: {
    feedUrl: string;
    title?: string;
    siteUrl?: string;
    customIconUrl?: string;
  }): Promise<{ uri: string; cid: string }> {
    const now = new Date().toISOString();
    const record: SkyreaderFeedSubscriptionRecord = {
      $type: COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
      createdAt: now,
      updatedAt: now,
      feedUrl: input.feedUrl,
      source: "the-social-wire",
      sourceType: "rss",
      ...(input.title?.trim() ? { title: input.title.trim() } : {}),
      ...(input.siteUrl?.trim()
        ? { siteUrl: input.siteUrl.trim() }
        : {}),
      ...(input.customIconUrl?.trim()
        ? { customIconUrl: input.customIconUrl.trim() }
        : {}),
    };
    const response = await this.agent.api.com.atproto.repo.createRecord({
      repo: this.did,
      collection: COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
      record: record as unknown as Record<string, unknown>,
    });
    return { uri: response.data.uri, cid: response.data.cid };
  }

  async deleteSkyreaderFeedSubscription(rkey: string): Promise<void> {
    await this.agent.api.com.atproto.repo.deleteRecord({
      repo: this.did,
      collection: COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
      rkey,
    });
  }

  /**
   * Updates branding fields on an existing Skyreader subscription (`putRecord`).
   */
  async updateSkyreaderFeedSubscription(params: {
    rkey: string;
    /** Pass `null` or empty string to clear `customIconUrl` on the record. Omit to leave unchanged. */
    customIconUrl?: string | null;
    /** Pass `null` or empty string to clear `siteUrl`. Omit to leave unchanged. */
    siteUrl?: string | null;
  }): Promise<{ uri: string; cid: string }> {
    const current = await this.agent.api.com.atproto.repo.getRecord({
      repo: this.did,
      collection: COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
      rkey: params.rkey,
    });
    const prev = current.data.value as unknown as SkyreaderFeedSubscriptionRecord;
    const now = new Date().toISOString();

    const record: Record<string, unknown> = {
      ...(prev as unknown as Record<string, unknown>),
      $type: COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
      updatedAt: now,
    };

    if (params.customIconUrl !== undefined) {
      const t = params.customIconUrl?.trim();
      if (!t) delete record.customIconUrl;
      else record.customIconUrl = t;
    }

    if (params.siteUrl !== undefined) {
      const t = params.siteUrl?.trim();
      if (!t) delete record.siteUrl;
      else record.siteUrl = t;
    }

    const updated = await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
      rkey: params.rkey,
      record,
    });
    return { uri: updated.data.uri, cid: updated.data.cid };
  }

  async upsertPublicationPrefs(
    publicationId: string,
    updates: Partial<Pick<PublicationPrefsRecord, "sortOrder" | "hidden">> & {
      folderId?: string | null;
    },
    existingRkey?: string
  ): Promise<{ uri: string; cid: string }> {
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

    if (!existingRkey) {
      const created = await this.agent.api.com.atproto.repo.createRecord({
        repo: this.did,
        collection: COLLECTION_PUB_PREFS,
        record: record as unknown as Record<string, unknown>,
      });
      return { uri: created.data.uri, cid: created.data.cid };
    }

    const updated = await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_PUB_PREFS,
      rkey: existingRkey,
      record: record as unknown as Record<string, unknown>,
    });

    return { uri: updated.data.uri, cid: updated.data.cid };
  }

  async deletePublicationPrefs(rkey: string): Promise<void> {
    await this.agent.api.com.atproto.repo.deleteRecord({
      repo: this.did,
      collection: COLLECTION_PUB_PREFS,
      rkey,
    });
  }

  // ── Account preferences ───────────────────────────────────────────────────

  async getPreferences(): Promise<RepoRecord<PreferencesRecord> | null> {
    try {
      const response = await this.agent.api.com.atproto.repo.getRecord({
        repo: this.did,
        collection: COLLECTION_PREFERENCES,
        rkey: PREFERENCES_RKEY,
      });
      return response.data as unknown as RepoRecord<PreferencesRecord>;
    } catch {
      return null;
    }
  }

  async upsertPreferences(
    updates: Partial<
      Pick<PreferencesRecord, "readLaterService" | "readLaterConnections">
    >
  ): Promise<{ uri: string; cid: string }> {
    const current = await this.getPreferences();
    const prev = current?.value ?? null;
    const now = new Date().toISOString();
    const record: PreferencesRecord = {
      $type: COLLECTION_PREFERENCES,
      createdAt: prev?.createdAt ?? now,
      updatedAt: now,
      ...(prev?.readLaterService ? { readLaterService: prev.readLaterService } : {}),
      ...(prev?.readLaterConnections
        ? { readLaterConnections: prev.readLaterConnections }
        : {}),
      ...updates,
    };

    const updated = await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_PREFERENCES,
      rkey: PREFERENCES_RKEY,
      record: record as unknown as Record<string, unknown>,
    });

    return { uri: updated.data.uri, cid: updated.data.cid };
  }

  // ── L@tr read-later (`com.latr.saved.*`) ──────────────────────────────────

  async listLatrSavedExternals(signal?: AbortSignal): Promise<RepoRecord<LatrSavedExternalRecord>[]> {
    const all: RepoRecord<LatrSavedExternalRecord>[] = [];
    let cursor: string | undefined;
    do {
      signal?.throwIfAborted();
      const response = await this.agent.api.com.atproto.repo.listRecords({
        repo: this.did,
        collection: COLLECTION_LATR_SAVED_EXTERNAL,
        limit: 100,
        cursor,
      });
      all.push(
        ...(response.data.records as unknown as RepoRecord<LatrSavedExternalRecord>[])
      );
      cursor = response.data.cursor ?? undefined;
    } while (cursor);
    return all;
  }

  async listLatrSavedItems(signal?: AbortSignal): Promise<RepoRecord<LatrSavedItemRecord>[]> {
    const all: RepoRecord<LatrSavedItemRecord>[] = [];
    let cursor: string | undefined;
    do {
      signal?.throwIfAborted();
      const response = await this.agent.api.com.atproto.repo.listRecords({
        repo: this.did,
        collection: COLLECTION_LATR_SAVED_ITEM,
        limit: 100,
        cursor,
      });
      all.push(
        ...(response.data.records as unknown as RepoRecord<LatrSavedItemRecord>[])
      );
      cursor = response.data.cursor ?? undefined;
    } while (cursor);
    return all;
  }

  /**
   * Idempotent HTTPS read-later slot (deterministic repo keys aligned with latr-link):
   * upserts `com.latr.saved.external` plus a `com.latr.saved.item` pointing at its AT URI.
   */
  async saveHttpsReadLater(
    displayUrlHttps: string,
    options?: { title?: string; excerpt?: string }
  ): Promise<{ externalUri: string; itemUri: string }> {
    const normalizedUrl = normalizeLatrHttpsUrl(displayUrlHttps);
    if (!normalizedUrl) {
      throw new Error("Cannot save — URL must be a non-empty HTTPS (or HTTP) location");
    }

    const urlAsSaved = normalizeHttpUrlToHttps(displayUrlHttps.trim());

    const externalRkey =
      await latrExternalRkeyFromNormalizedUrl(normalizedUrl);

    let prevExternal: LatrSavedExternalRecord | null = null;
    try {
      const current = await this.agent.api.com.atproto.repo.getRecord({
        repo: this.did,
        collection: COLLECTION_LATR_SAVED_EXTERNAL,
        rkey: externalRkey,
      });
      prevExternal = current.data.value as unknown as LatrSavedExternalRecord;
    } catch {
      prevExternal = null;
    }

    const titleNext =
      options?.title?.trim() || prevExternal?.title?.trim() || undefined;
    const excerptNext =
      options?.excerpt?.trim() || prevExternal?.excerpt?.trim() || undefined;

    const externalRecord: LatrSavedExternalRecord = {
      $type: COLLECTION_LATR_SAVED_EXTERNAL,
      url: urlAsSaved,
      normalizedUrl,
      fingerprint: await latrFingerprintFromNormalizedUrl(normalizedUrl),
      createdAt: prevExternal?.createdAt ?? new Date().toISOString(),
      ...(titleNext ? { title: titleNext } : {}),
      ...(excerptNext ? { excerpt: excerptNext } : {}),
      ...(prevExternal?.site ? { site: prevExternal.site } : {}),
      ...(prevExternal?.image ? { image: prevExternal.image } : {}),
      ...(prevExternal?.language ? { language: prevExternal.language } : {}),
      ...(prevExternal?.publishedAt ? { publishedAt: prevExternal.publishedAt } : {}),
      ...(prevExternal?.author ? { author: prevExternal.author } : {}),
    };

    await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_LATR_SAVED_EXTERNAL,
      rkey: externalRkey,
      record: externalRecord as unknown as Record<string, unknown>,
    });

    const externalUri =
      `at://${this.did}/${COLLECTION_LATR_SAVED_EXTERNAL}/${externalRkey}`;

    const itemRkey =
      await latrItemRkeyFromSubjectUri(externalUri);

    let prevItem: LatrSavedItemRecord | null = null;
    try {
      const currentItem = await this.agent.api.com.atproto.repo.getRecord({
        repo: this.did,
        collection: COLLECTION_LATR_SAVED_ITEM,
        rkey: itemRkey,
      });
      prevItem = currentItem.data.value as unknown as LatrSavedItemRecord;
    } catch {
      prevItem = null;
    }

    const savedAtNow = new Date().toISOString();

    const itemRecord: LatrSavedItemRecord = {
      $type: COLLECTION_LATR_SAVED_ITEM,
      subjectUri: externalUri,
      savedAt: savedAtNow,
      ...(prevItem?.state !== undefined ? { state: prevItem.state } : {}),
      ...(prevItem?.tags ? { tags: prevItem.tags } : {}),
      ...(prevItem?.note ? { note: prevItem.note } : {}),
      ...(prevItem?.lastOpenedAt
        ? { lastOpenedAt: prevItem.lastOpenedAt }
        : {}),
    };

    await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_LATR_SAVED_ITEM,
      rkey: itemRkey,
      record: itemRecord as unknown as Record<string, unknown>,
    });

    const itemUri = `at://${this.did}/${COLLECTION_LATR_SAVED_ITEM}/${itemRkey}`;

    return { externalUri, itemUri };
  }

  /**
   * Remove a queued HTTPS save (both item + external wrappers) using normalized URL semantics.
   */
  async deleteHttpsReadLater(normalizedUrl: string): Promise<void> {
    const n = normalizeLatrHttpsUrl(normalizedUrl.trim());
    if (!n) {
      throw new Error("Cannot delete — normalized URL missing");
    }
    const externalRkey = await latrExternalRkeyFromNormalizedUrl(n);
    const externalUri =
      `at://${this.did}/${COLLECTION_LATR_SAVED_EXTERNAL}/${externalRkey}`;
    const itemRkey = await latrItemRkeyFromSubjectUri(externalUri);

    try {
      await this.agent.api.com.atproto.repo.deleteRecord({
        repo: this.did,
        collection: COLLECTION_LATR_SAVED_ITEM,
        rkey: itemRkey,
      });
    } catch {
      /* best-effort: record may already be absent */
    }

    try {
      await this.agent.api.com.atproto.repo.deleteRecord({
        repo: this.did,
        collection: COLLECTION_LATR_SAVED_EXTERNAL,
        rkey: externalRkey,
      });
    } catch {
      /* best-effort */
    }
  }

  async archiveHttpsReadLater(normalizedUrl: string): Promise<void> {
    const n = normalizeLatrHttpsUrl(normalizedUrl.trim());
    if (!n) {
      throw new Error("Cannot archive — normalized URL missing");
    }
    const externalRkey = await latrExternalRkeyFromNormalizedUrl(n);
    const externalUri =
      `at://${this.did}/${COLLECTION_LATR_SAVED_EXTERNAL}/${externalRkey}`;
    const itemRkey = await latrItemRkeyFromSubjectUri(externalUri);

    const currentItem = await this.agent.api.com.atproto.repo.getRecord({
      repo: this.did,
      collection: COLLECTION_LATR_SAVED_ITEM,
      rkey: itemRkey,
    });
    const prevItem = currentItem.data.value as unknown as LatrSavedItemRecord;

    const itemRecord: LatrSavedItemRecord = {
      $type: COLLECTION_LATR_SAVED_ITEM,
      subjectUri: prevItem.subjectUri,
      savedAt: prevItem.savedAt,
      state: "archived",
      ...(prevItem.tags ? { tags: prevItem.tags } : {}),
      ...(prevItem.note ? { note: prevItem.note } : {}),
      ...(prevItem.lastOpenedAt
        ? { lastOpenedAt: prevItem.lastOpenedAt }
        : {}),
    };

    await this.agent.api.com.atproto.repo.putRecord({
      repo: this.did,
      collection: COLLECTION_LATR_SAVED_ITEM,
      rkey: itemRkey,
      record: itemRecord as unknown as Record<string, unknown>,
    });
  }

  /** Joins wrappers with queue rows for read-later browsing. */
  async listMergedLatrSaves(signal?: AbortSignal): Promise<MergedLatrSave[]> {
    const externals = await this.listLatrSavedExternals(signal);
    const items = await this.listLatrSavedItems(signal);
    signal?.throwIfAborted();
    const rows = mergeExternalsAndItemsToHttpsRows(externals, items).filter(
      (row) => row.state !== "archived"
    );
    return Promise.all(
      rows.map(async (row): Promise<MergedLatrSave> => {
        if (row.kind !== "native") return row;
        const preview = await this.resolveNativePreview(row.subjectUri);
        if (!preview) return row;
        return { ...row, ...preview };
      })
    );
  }

  /** @deprecated Use listMergedLatrSaves. */
  async listMergedLatrHttpsSaves(): Promise<MergedLatrSave[]> {
    return this.listMergedLatrSaves();
  }

  private async resolveNativePreview(
    subjectUri: string
  ): Promise<NativeSavedSubjectPreview | null> {
    try {
      return await resolveNativeSavedSubjectPreview(subjectUri, this.oauthSession);
    } catch {
      return null;
    }
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Extracts the rkey from an at-uri.
 * at://did:plc:xxx/com.thesocialwire.folder/rkey → "rkey"
 */
export function rkeyFromURI(uri: string): string {
  return uri.split("/").pop() ?? uri;
}
