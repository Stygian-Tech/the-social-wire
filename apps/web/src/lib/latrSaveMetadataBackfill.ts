import type { OAuthSession } from "@atproto/oauth-client-browser";

import { resolveNativeSavedSubjectPreview } from "@/lib/atprotoClient";
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

/** HTTPS URL the Latr gateway can scrape for OG metadata. */
export function backfillUrlForLatrSave(row: MergedLatrSave): string | null {
  if (row.kind === "external") {
    return row.url?.trim() || row.normalizedUrl?.trim() || null;
  }
  return row.linkedWebUrl?.trim() || row.url?.trim() || null;
}

/** Mirrors L@tr.link `isWeakPreviewTitle` — hostname, site label, slug, etc. */
export function isWeakLatrSaveTitle(
  title: string,
  siteLabel: string | undefined,
  linkedWebUrl: string
): boolean {
  const trimmed = title.trim();
  if (!trimmed) return true;

  let hostname: string | undefined;
  try {
    hostname = new URL(linkedWebUrl).hostname.replace(/^www\./i, "");
  } catch {
    hostname = undefined;
  }

  const lower = trimmed.toLowerCase();
  if (siteLabel && lower === siteLabel.trim().toLowerCase()) return true;
  if (hostname && lower === hostname.toLowerCase()) return true;
  if (hostname && lower === `www.${hostname}`.toLowerCase()) return true;

  const genericTitles = ["home", "homepage", "the verge", "verge", "news", "latest"];
  if (genericTitles.includes(lower)) return true;

  try {
    if (trimmed === linkedWebUrl.trim()) return true;
    if (new URL(trimmed).href === new URL(linkedWebUrl).href) return true;
  } catch {
    /* title is not a URL */
  }

  try {
    const parts = new URL(linkedWebUrl).pathname.split("/").filter(Boolean);
    const last = parts[parts.length - 1];
    if (last) {
      const slugTitle = last
        .replace(/_/g, "-")
        .split("-")
        .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
        .join(" ");
      if (trimmed.toLowerCase() === slugTitle.toLowerCase()) return true;
    }
  } catch {
    /* ignore */
  }

  return false;
}

/** True when OG backfill may improve titles and/or thumbnails. */
export function needsLatrSaveOgBackfill(row: MergedLatrSave): boolean {
  const url = backfillUrlForLatrSave(row);
  if (!url) return false;

  const title = row.title?.trim();
  if (!title) return true;
  if (!row.image?.trim()) return true;
  return isWeakLatrSaveTitle(title, row.site, url);
}

/** @deprecated Use {@link needsLatrSaveOgBackfill}. */
export function isLatrSaveMetadataSparse(row: MergedLatrSave): boolean {
  return needsLatrSaveOgBackfill(row);
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

/** Merge OG preview fields like L@tr.link `backfillPreviewFromOpenGraph`. */
export function mergeLatrSaveBackfillMetadata(
  row: MergedLatrSave,
  backfill: LatrSaveMetadata
): MergedLatrSave {
  const linkedWebUrl = backfillUrlForLatrSave(row) ?? backfill.linkedWebUrl;
  const weakTitle =
    linkedWebUrl && row.title?.trim()
      ? isWeakLatrSaveTitle(row.title, row.site, linkedWebUrl)
      : !row.title?.trim();
  const missingImage = !row.image?.trim();

  return {
    ...row,
    title:
      (weakTitle ? backfill.title : undefined) ||
      row.title?.trim() ||
      backfill.title,
    excerpt: row.excerpt?.trim() || backfill.excerpt,
    image:
      (missingImage ? backfill.image : undefined) ||
      row.image?.trim() ||
      backfill.image,
    site: row.site?.trim() || backfill.site,
    author: row.author?.trim() || backfill.author,
    publishedAt: row.publishedAt?.trim() || backfill.publishedAt,
    language: row.language?.trim() || backfill.language,
    linkedWebUrl: row.linkedWebUrl?.trim() || backfill.linkedWebUrl || linkedWebUrl,
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
  return resolveLatrSaveRowDisplay(oauthSession, row, options);
}

/**
 * Resolve saved-link card metadata for display (aligned with L@tr.link
 * `resolveSubjectPreviewForRow`).
 */
export async function resolveLatrSaveRowDisplay(
  oauthSession: OAuthSession,
  row: MergedLatrSave,
  options: { reconcileToPds?: boolean } = {}
): Promise<MergedLatrSave> {
  let enriched = row;

  if (row.kind === "native") {
    try {
      const preview = await resolveNativeSavedSubjectPreview(
        row.subjectUri,
        oauthSession
      );
      if (preview) {
        enriched = {
          ...enriched,
          ...(preview.url ? { url: preview.url } : {}),
          ...(preview.url && !enriched.linkedWebUrl
            ? { linkedWebUrl: preview.url }
            : {}),
          title: enriched.title?.trim() || preview.title,
          excerpt: enriched.excerpt?.trim() || preview.excerpt,
          image: enriched.image?.trim() || preview.image,
        };
      }
    } catch {
      /* ignore subject resolution failures */
    }
  }

  if (needsLatrSaveOgBackfill(enriched)) {
    const url = backfillUrlForLatrSave(enriched);
    if (url) {
      const preview = await fetchLatrOgPreview(oauthSession, url);
      if (preview) {
        enriched = mergeLatrSaveBackfillMetadata(enriched, preview);
      }
    }
  }

  if (options.reconcileToPds && needsLatrSaveOgBackfill(enriched)) {
    void reconcileSparseLatrSaveOnGateway(oauthSession, enriched);
  }

  return enriched;
}
