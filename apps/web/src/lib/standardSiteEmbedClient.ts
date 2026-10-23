import type { OAuthSession } from "@atproto/oauth-client-browser";
import { socialWireXrpc } from "@/lib/socialWireXrpc";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { parseAtUri } from "@/lib/atprotoClient";

export interface StandardSiteEmbed {
  documentUri: string;
  publicationUri: string;
  publicationName: string;
  publicationUrl: string;
  articleUrl: string;
  title: string;
  description?: string;
  authorDid: string;
}

export function parseStandardSiteEmbed(value: unknown): StandardSiteEmbed | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  for (const key of ["documentUri", "publicationUri", "publicationName", "publicationUrl", "articleUrl", "title", "authorDid"]) {
    if (typeof row[key] !== "string" || !row[key]) return null;
  }
  if (!["site.standard.document", "site.standard.entry"].includes(parseAtUri(row.documentUri as string)?.collection ?? "") ||
      parseAtUri(row.publicationUri as string)?.collection !== "site.standard.publication") return null;
  for (const key of ["articleUrl", "publicationUrl"]) {
    try {
      const url = new URL(row[key] as string);
      if (url.protocol !== "https:" || url.username || url.password) return null;
    } catch { return null; }
  }
  if (row.description !== undefined && typeof row.description !== "string") return null;
  return row as unknown as StandardSiteEmbed;
}

export async function fetchStandardSiteEmbed(session: OAuthSession, url: string, signal?: AbortSignal): Promise<StandardSiteEmbed | null> {
  const response = await gatewayFetch(session, `${socialWireXrpc.getArticleEmbed}?${new URLSearchParams({ url })}`, { signal });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error("Article details are temporarily unavailable.");
  const metadata = parseStandardSiteEmbed(await response.json());
  if (!metadata) throw new Error("Invalid article details.");
  return metadata;
}
