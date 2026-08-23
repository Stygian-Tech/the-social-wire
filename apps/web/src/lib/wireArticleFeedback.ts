export const WIRE_ARTICLE_FEEDBACK_COLLECTION =
  "app.thesocialwire.wireFeedback";

export type WireArticleFeedbackValue = "good" | "not_good";

export interface WireArticleFeedbackRecord {
  $type: typeof WIRE_ARTICLE_FEEDBACK_COLLECTION;
  canonicalUrl: string;
  subject?: string;
  value: WireArticleFeedbackValue;
  createdAt: string;
  updatedAt: string;
}

export function normalizeWireFeedbackUrl(value: string): string | null {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

export async function wireFeedbackRkey(canonicalUrl: string): Promise<string> {
  const normalized = normalizeWireFeedbackUrl(canonicalUrl);
  if (!normalized) throw new Error("Article feedback requires a public article URL.");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(normalized),
  );
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}
