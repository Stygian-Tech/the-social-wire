import type { OAuthSession } from "@atproto/oauth-client-browser";

import { COLLECTION_LATR_SAVED_EXTERNAL } from "@/lib/latrCollections";
import { latrGatewayJson } from "@/lib/latrGatewayClient";
import {
  latrExternalRkeyFromNormalizedUrl,
  latrItemRkeyFromSubjectUri,
  normalizeLatrHttpsUrl,
} from "@/lib/latrSavedUrls";
import type { PDSClient } from "@/lib/pdsClient";

export type ReadLaterProviderId = "latr-gateway" | "pds-direct";

export interface ReadLaterProvider {
  readonly id: ReadLaterProviderId;
  saveHttpsUrl(url: string, options?: { title?: string; excerpt?: string }): Promise<void>;
  saveNativeSubject(subjectUri: string, linkedWebUrl?: string): Promise<void>;
  deleteSaveItem(itemRkey: string): Promise<void>;
  archiveSaveItem(itemRkey: string): Promise<void>;
  unarchiveSaveItem(itemRkey: string): Promise<void>;
  /** @deprecated Prefer deleteSaveItem(itemRkey). */
  deleteHttpsUrl(normalizedUrl: string): Promise<void>;
  /** @deprecated Prefer archiveSaveItem(itemRkey). */
  archiveHttpsUrl(normalizedUrl: string): Promise<void>;
}

function readLaterProviderId(): ReadLaterProviderId {
  const flag = process.env.NEXT_PUBLIC_LATR_READ_LATER_PROVIDER?.trim();
  if (flag === "pds-direct") return "pds-direct";
  return "latr-gateway";
}

class LatrGatewayReadLaterProvider implements ReadLaterProvider {
  readonly id = "latr-gateway" as const;

  constructor(
    private readonly oauthSession: OAuthSession,
    private readonly pdsClient: PDSClient,
    private readonly viewerDid: string
  ) {}

  private async withPdsFallback<T>(
    gatewayCall: () => Promise<T>,
    pdsFallback: () => Promise<T>
  ): Promise<T> {
    try {
      return await gatewayCall();
    } catch {
      return pdsFallback();
    }
  }

  async saveHttpsUrl(
    url: string,
    options?: { title?: string; excerpt?: string }
  ): Promise<void> {
    await this.withPdsFallback(
      () =>
        latrGatewayJson(this.oauthSession, "/v1/latr/saves", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            kind: "url",
            url,
            ...(options?.title?.trim() ? { title: options.title.trim() } : {}),
            ...(options?.excerpt?.trim() ? { excerpt: options.excerpt.trim() } : {}),
          }),
        }),
      () => this.pdsClient.saveHttpsReadLater(url, options).then(() => undefined)
    );
  }

  async saveNativeSubject(subjectUri: string, linkedWebUrl?: string): Promise<void> {
    await latrGatewayJson(this.oauthSession, "/v1/latr/saves", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind: "subject",
        subjectUri,
        ...(linkedWebUrl?.trim() ? { linkedWebUrl: linkedWebUrl.trim() } : {}),
      }),
    });
  }

  async deleteSaveItem(itemRkey: string): Promise<void> {
    await this.withPdsFallback(
      () =>
        latrGatewayJson(
          this.oauthSession,
          `/v1/latr/saves/${encodeURIComponent(itemRkey)}`,
          { method: "DELETE" }
        ),
      () => this.pdsClient.deleteLatrSaveItem(itemRkey)
    );
  }

  async archiveSaveItem(itemRkey: string): Promise<void> {
    await this.withPdsFallback(
      () => this.patchSaveState(itemRkey, "archived"),
      () => this.pdsClient.setLatrSaveItemState(itemRkey, "archived")
    );
  }

  async unarchiveSaveItem(itemRkey: string): Promise<void> {
    await this.withPdsFallback(
      () => this.patchSaveState(itemRkey, "unread"),
      () => this.pdsClient.setLatrSaveItemState(itemRkey, "unread")
    );
  }

  async deleteHttpsUrl(normalizedUrl: string): Promise<void> {
    await this.deleteSaveItem(await this.httpsItemRkey(normalizedUrl));
  }

  async archiveHttpsUrl(normalizedUrl: string): Promise<void> {
    await this.archiveSaveItem(await this.httpsItemRkey(normalizedUrl));
  }

  private async patchSaveState(
    itemRkey: string,
    state: "archived" | "unread"
  ): Promise<void> {
    await latrGatewayJson(
      this.oauthSession,
      `/v1/latr/saves/${encodeURIComponent(itemRkey)}/state`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ state }),
      }
    );
  }

  private async httpsItemRkey(normalizedUrl: string): Promise<string> {
    const n = normalizeLatrHttpsUrl(normalizedUrl.trim());
    if (!n) throw new Error("Cannot resolve save — normalized URL missing");
    const externalRkey = await latrExternalRkeyFromNormalizedUrl(n);
    const externalUri = `at://${this.viewerDid}/${COLLECTION_LATR_SAVED_EXTERNAL}/${externalRkey}`;
    return latrItemRkeyFromSubjectUri(externalUri);
  }
}

class PdsDirectReadLaterProvider implements ReadLaterProvider {
  readonly id = "pds-direct" as const;

  constructor(private readonly pdsClient: PDSClient) {}

  async saveHttpsUrl(
    url: string,
    options?: { title?: string; excerpt?: string }
  ): Promise<void> {
    await this.pdsClient.saveHttpsReadLater(url, options);
  }

  async saveNativeSubject(subjectUri: string, linkedWebUrl?: string): Promise<void> {
    void subjectUri;
    void linkedWebUrl;
    throw new Error(
      "Native subject saves require the latr-gateway read-later provider"
    );
  }

  async deleteSaveItem(itemRkey: string): Promise<void> {
    await this.pdsClient.deleteLatrSaveItem(itemRkey);
  }

  async archiveSaveItem(itemRkey: string): Promise<void> {
    await this.pdsClient.setLatrSaveItemState(itemRkey, "archived");
  }

  async unarchiveSaveItem(itemRkey: string): Promise<void> {
    await this.pdsClient.setLatrSaveItemState(itemRkey, "unread");
  }

  async deleteHttpsUrl(normalizedUrl: string): Promise<void> {
    await this.pdsClient.deleteHttpsReadLater(normalizedUrl);
  }

  async archiveHttpsUrl(normalizedUrl: string): Promise<void> {
    await this.pdsClient.archiveHttpsReadLater(normalizedUrl);
  }
}

export function createReadLaterProvider(
  oauthSession: OAuthSession,
  pdsClient: PDSClient,
  viewerDid: string
): ReadLaterProvider {
  if (readLaterProviderId() === "pds-direct") {
    return new PdsDirectReadLaterProvider(pdsClient);
  }
  return new LatrGatewayReadLaterProvider(oauthSession, pdsClient, viewerDid);
}
