import type { OAuthSession } from "@atproto/oauth-client-browser";

import { LatrBookmarksClient } from "@/lib/latrBookmarks";
import type { PDSClient } from "@/lib/pdsClient";
import type { LatrListTagsOutput, LatrTagMutationResult } from "latr-packages/gateway-client";

export type ReadLaterProviderId = "latr-gateway";

export interface ReadLaterProvider {
  readonly id: ReadLaterProviderId;
  saveSubject(subject: string, tags?: string[]): Promise<void>;
  listTags(cursor?: string): Promise<LatrListTagsOutput>;
  setSaveItemTags(bookmarkUri: string, tags: string[]): Promise<void>;
  renameTagPage(input: { tag: string; replacement: string; cursor?: string; limit?: number }): Promise<LatrTagMutationResult>;
  deleteTagPage(input: { tag: string; cursor?: string; limit?: number }): Promise<LatrTagMutationResult>;
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

  async saveSubject(subject: string, tags?: string[]): Promise<void> {
    await this.bookmarks.save(subject, tags);
  }

  listTags(cursor?: string): Promise<LatrListTagsOutput> {
    return this.bookmarks.listTags(cursor);
  }

  async setSaveItemTags(bookmarkUri: string, tags: string[]): Promise<void> {
    await this.bookmarks.setTags(bookmarkUri, tags);
  }

  renameTagPage(input: { tag: string; replacement: string; cursor?: string; limit?: number }): Promise<LatrTagMutationResult> {
    return this.bookmarks.renameTagPage(input);
  }

  deleteTagPage(input: { tag: string; cursor?: string; limit?: number }): Promise<LatrTagMutationResult> {
    return this.bookmarks.deleteTagPage(input);
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
