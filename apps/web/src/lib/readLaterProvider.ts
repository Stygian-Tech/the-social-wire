import type { OAuthSession } from "@atproto/oauth-client-browser";

import { LatrBookmarksClient } from "@/lib/latrBookmarks";
import type { PDSClient } from "@/lib/pdsClient";

export type ReadLaterProviderId = "latr-gateway";

export interface ReadLaterProvider {
  readonly id: ReadLaterProviderId;
  saveSubject(subject: string): Promise<void>;
  deleteSaveItem(bookmarkUri: string): Promise<void>;
  archiveSaveItem(bookmarkUri: string): Promise<void>;
  unarchiveSaveItem(bookmarkUri: string): Promise<void>;
}

class LatrGatewayReadLaterProvider implements ReadLaterProvider {
  readonly id = "latr-gateway" as const;

  private readonly bookmarks: LatrBookmarksClient;

  constructor(oauthSession: OAuthSession) {
    this.bookmarks = new LatrBookmarksClient(oauthSession);
  }

  async saveSubject(subject: string): Promise<void> {
    await this.bookmarks.save(subject);
  }

  async deleteSaveItem(bookmarkUri: string): Promise<void> {
    await this.bookmarks.delete(bookmarkUri);
  }

  async archiveSaveItem(bookmarkUri: string): Promise<void> {
    await this.bookmarks.setState(bookmarkUri, "archived");
  }

  async unarchiveSaveItem(bookmarkUri: string): Promise<void> {
    await this.bookmarks.setState(bookmarkUri, "unread");
  }
}

export function createReadLaterProvider(
  oauthSession: OAuthSession,
  pdsClient: PDSClient,
  viewerDid: string
): ReadLaterProvider {
  void pdsClient;
  void viewerDid;
  return new LatrGatewayReadLaterProvider(oauthSession);
}
