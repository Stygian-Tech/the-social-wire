import type { OAuthSession } from "@atproto/oauth-client-browser";

import {
  isLatrGatewayAuthRejected,
} from "@/lib/latrGatewayCredentials";
import { latrGatewayJson } from "@/lib/latrGatewayClient";
import type { LatrSaveMetadata, MergedLatrSave } from "@/lib/pdsClient";

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function latrGatewayMutationsEnabled(): boolean {
  const flag = process.env.NEXT_PUBLIC_LATR_READ_LATER_PROVIDER?.trim();
  return flag !== "pds-direct";
}

function hostnameFromUrl(raw: string | undefined): string | null {
  if (!raw?.trim()) return null;
  try {
    return new URL(raw.trim()).hostname.toLowerCase();
  } catch {
    return null;
  }
}

/** True when card fields are missing or only hostname placeholders remain. */
export function isLatrSaveMetadataSparse(row: MergedLatrSave): boolean {
  const hasImage = Boolean(row.image?.trim());
  const title = row.title?.trim();
  if (!title) return true;
  if (!hasImage) return true;

  const url = backfillUrlForLatrSave(row);
  const host = hostnameFromUrl(url ?? undefined);
  if (host && title.toLowerCase() === host) return true;

  return false;
}

/** HTTPS URL the Latr gateway can scrape for OG metadata. */
export function backfillUrlForLatrSave(row: MergedLatrSave): string | null {
  if (row.kind === "external") {
    return row.url?.trim() || row.normalizedUrl?.trim() || null;
  }
  return row.linkedWebUrl?.trim() || row.url?.trim() || null;
}

function parseOgPreviewResponse(
  data: Record<string, unknown>
): LatrSaveMetadata | null {
  const title = str(data.title) ?? str(data.ogTitle);
  const excerpt =
    str(data.excerpt) ?? str(data.description) ?? str(data.ogDescription);
  const image =
    str(data.image) ?? str(data.ogImage) ?? str(data.thumbnailUrl);
  const site = str(data.site) ?? str(data.siteName);
  const author = str(data.author);
  const publishedAt = str(data.publishedAt);
  const language = str(data.language);

  if (!title && !image && !excerpt && !site) return null;

  return {
    ...(title ? { title } : {}),
    ...(excerpt ? { excerpt } : {}),
    ...(image ? { image } : {}),
    ...(site ? { site } : {}),
    ...(author ? { author } : {}),
    ...(publishedAt ? { publishedAt } : {}),
    ...(language ? { language } : {}),
  };
}

/** Read-only OG preview from the Latr gateway (no PDS write). */
export async function fetchLatrOgPreview(
  oauthSession: OAuthSession,
  url: string
): Promise<LatrSaveMetadata | null> {
  if (!latrGatewayMutationsEnabled() || isLatrGatewayAuthRejected()) {
    return null;
  }

  const params = new URLSearchParams({ url: url.trim() });
  try {
    const data = await withOgPreviewSlot(() =>
      latrGatewayJson<Record<string, unknown>>(
        oauthSession,
        `/v1/latr/og-preview?${params}`,
        { method: "GET" }
      )
    );
    return parseOgPreviewResponse(data);
  } catch {
    return null;
  }
}

export function mergeLatrSaveBackfillMetadata(
  row: MergedLatrSave,
  backfill: LatrSaveMetadata
): MergedLatrSave {
  return {
    ...row,
    title: row.title?.trim() || backfill.title,
    excerpt: row.excerpt?.trim() || backfill.excerpt,
    image: row.image?.trim() || backfill.image,
    site: row.site?.trim() || backfill.site,
    author: row.author?.trim() || backfill.author,
    publishedAt: row.publishedAt?.trim() || backfill.publishedAt,
    language: row.language?.trim() || backfill.language,
    linkedWebUrl: row.linkedWebUrl?.trim() || backfill.linkedWebUrl,
  };
}

const reconciledItemRkeys = new Set<string>();

const OG_PREVIEW_MAX_CONCURRENT = 2;
let ogPreviewInFlight = 0;
const ogPreviewWaiters: Array<() => void> = [];

async function withOgPreviewSlot<T>(fn: () => Promise<T>): Promise<T> {
  if (ogPreviewInFlight >= OG_PREVIEW_MAX_CONCURRENT) {
    await new Promise<void>((resolve) => {
      ogPreviewWaiters.push(resolve);
    });
  }
  ogPreviewInFlight += 1;
  try {
    return await fn();
  } finally {
    ogPreviewInFlight -= 1;
    ogPreviewWaiters.shift()?.();
  }
}

/** Idempotent gateway save that re-enriches sparse legacy rows on the viewer PDS. */
export async function reconcileSparseLatrSaveOnGateway(
  oauthSession: OAuthSession,
  row: MergedLatrSave
): Promise<void> {
  if (!latrGatewayMutationsEnabled() || isLatrGatewayAuthRejected()) {
    return;
  }
  if (reconciledItemRkeys.has(row.itemRkey)) return;
  reconciledItemRkeys.add(row.itemRkey);

  try {
    if (row.kind === "external") {
      await latrGatewayJson(oauthSession, "/v1/latr/saves", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          kind: "url",
          url: row.url,
          ...(row.title?.trim() ? { title: row.title.trim() } : {}),
          ...(row.excerpt?.trim() ? { excerpt: row.excerpt.trim() } : {}),
        }),
      });
      return;
    }

    const linkedWebUrl = backfillUrlForLatrSave(row);
    await latrGatewayJson(oauthSession, "/v1/latr/saves", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind: "subject",
        subjectUri: row.subjectUri,
        ...(linkedWebUrl ? { linkedWebUrl } : {}),
      }),
    });
  } catch {
    reconciledItemRkeys.delete(row.itemRkey);
  }
}

/** Lazy gateway preview + optional PDS reconcile for legacy sparse saves. */
export async function enrichSparseLatrSaveRow(
  oauthSession: OAuthSession,
  row: MergedLatrSave,
  options: { reconcileToPds?: boolean } = {}
): Promise<MergedLatrSave> {
  if (!isLatrSaveMetadataSparse(row)) return row;

  const url = backfillUrlForLatrSave(row);
  let enriched = row;

  if (url) {
    const preview = await fetchLatrOgPreview(oauthSession, url);
    if (preview) {
      enriched = mergeLatrSaveBackfillMetadata(enriched, preview);
    }
  }

  if (options.reconcileToPds && isLatrSaveMetadataSparse(enriched)) {
    void reconcileSparseLatrSaveOnGateway(oauthSession, enriched);
  }

  return enriched;
}
