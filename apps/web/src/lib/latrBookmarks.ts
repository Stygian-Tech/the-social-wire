import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  createBookmarkMigrationRequestBody,
  LATR_XRPC,
  latrXrpcPath,
  type LatrBookmarkView,
  type LatrMigrationResult,
} from "latr-packages/gateway-client";

import { latrGatewayJson } from "@/lib/latrGatewayClient";
import { normalizeLatrHttpsUrl } from "@/lib/latrSavedUrls";
import type { LatrSaveListState, MergedLatrSave } from "@/lib/pdsClient";

export const LATR_BOOKMARK_CONTRACT_VERSION = "link.latr.bookmarks.v1";

export function bookmarkViewToRow(view: LatrBookmarkView): MergedLatrSave {
  const subject = view.value.subject.trim();
  const normalizedUrl = normalizeLatrHttpsUrl(subject);
  const preview = view.preview;
  const metadata = view.metadataRecord?.value;
  const shared = {
    savedAt: view.value.createdAt,
    itemRkey: view.uri,
    itemUri: view.uri,
    subjectUri: subject,
    state: metadata?.state ?? ("unread" as const),
    ...(metadata?.lastOpenedAt ? { lastOpenedAt: metadata.lastOpenedAt } : {}),
    ...(preview?.title ? { title: preview.title } : {}),
    ...(preview?.description ? { excerpt: preview.description } : {}),
    ...(preview?.image ? { image: preview.image } : {}),
    ...(preview?.siteName ? { site: preview.siteName } : {}),
    ...(preview?.author ? { author: preview.author } : {}),
  };

  if (normalizedUrl) {
    return {
      kind: "external",
      normalizedUrl,
      url: subject,
      externalRkey: "",
      externalUri: subject,
      ...shared,
    };
  }
  return { kind: "native", ...shared };
}

export class LatrBookmarksClient {
  constructor(private readonly oauthSession: OAuthSession) {}

  async listAll(state: LatrSaveListState = "all"): Promise<MergedLatrSave[]> {
    const rows: MergedLatrSave[] = [];
    let cursor: string | undefined;
    do {
      const query = new URLSearchParams({ limit: "50" });
      if (cursor) query.set("cursor", cursor);
      const page = await latrGatewayJson<{
        bookmarks: LatrBookmarkView[];
        cursor?: string;
      }>(
        this.oauthSession,
        `${latrXrpcPath(LATR_XRPC.listBookmarks)}?${query.toString()}`
      );
      rows.push(...page.bookmarks.map(bookmarkViewToRow));
      cursor = page.cursor?.trim() || undefined;
    } while (cursor);

    return rows
      .filter((row) => {
        if (state === "all") return true;
        const rowState = row.state ?? "unread";
        return state === "archived"
          ? rowState === "archived"
          : rowState !== "archived";
      })
      .sort((left, right) => Date.parse(right.savedAt) - Date.parse(left.savedAt));
  }

  async getBySubject(subject: string): Promise<MergedLatrSave | undefined> {
    const query = new URLSearchParams({ subject });
    const result = await latrGatewayJson<{ bookmark?: LatrBookmarkView }>(
      this.oauthSession,
      `${latrXrpcPath(LATR_XRPC.getBookmark)}?${query.toString()}`
    );
    return result.bookmark ? bookmarkViewToRow(result.bookmark) : undefined;
  }

  async save(subject: string, tags?: string[]): Promise<MergedLatrSave> {
    const view = await latrGatewayJson<LatrBookmarkView>(
      this.oauthSession,
      latrXrpcPath(LATR_XRPC.saveBookmark),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ subject, ...(tags?.length ? { tags } : {}) }),
      }
    );
    return bookmarkViewToRow(view);
  }

  async setState(
    bookmarkUri: string,
    state: "unread" | "archived"
  ): Promise<void> {
    await latrGatewayJson(
      this.oauthSession,
      latrXrpcPath(LATR_XRPC.setBookmarkState),
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ bookmarkUri, state }),
      }
    );
  }

  async delete(bookmarkUri: string): Promise<void> {
    await latrGatewayJson(
      this.oauthSession,
      latrXrpcPath(LATR_XRPC.deleteBookmark),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ bookmarkUri }),
      }
    );
  }

  async migratePage(input: {
    limit?: number;
    cursor?: string;
  } = {}): Promise<LatrMigrationResult> {
    return latrGatewayJson(
      this.oauthSession,
      latrXrpcPath(LATR_XRPC.migrateBookmarks),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: await createBookmarkMigrationRequestBody(this.oauthSession, input),
      }
    );
  }
}

export type LatrMigrationSummary = LatrMigrationResult & {
  hasConflicts: boolean;
};

export async function migrateLegacyBookmarks(
  client: Pick<LatrBookmarksClient, "migratePage">
): Promise<LatrMigrationSummary> {
  let cursor: string | undefined;
  const total: LatrMigrationResult = {
    ok: true,
    scanned: 0,
    created: 0,
    reused: 0,
    duplicates: 0,
    skippedConflict: 0,
    cached: 0,
    retired: 0,
  };
  do {
    const page = await client.migratePage({ limit: 25, ...(cursor ? { cursor } : {}) });
    if (!page.ok) {
      throw new Error("L@tr legacy bookmark migration did not complete.");
    }
    total.ok = total.ok && page.ok;
    total.scanned += page.scanned;
    total.created += page.created;
    total.reused += page.reused;
    total.duplicates += page.duplicates;
    total.skippedConflict += page.skippedConflict;
    total.cached += page.cached;
    total.retired += page.retired;
    cursor = page.cursor?.trim() || undefined;
  } while (cursor);
  return { ...total, hasConflicts: total.skippedConflict > 0 };
}
