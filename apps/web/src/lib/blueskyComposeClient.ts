import { AppBskyRichtextFacet, RichText } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";

export function postTextLength(text: string): { graphemes: number; bytes: number } {
  return { graphemes: new RichText({ text }).graphemeLength, bytes: new TextEncoder().encode(text).length };
}

/** Called only by an explicit Post action; validation precedes all network requests. */
export async function createBlueskyPost(args: {
  session: OAuthSession;
  text: string;
  assertCurrentAccount?: () => void;
}): Promise<{ uri: string; cid: string }> {
  if (!args.text.trim()) throw new Error("Write something before posting.");
  const length = postTextLength(args.text);
  if (length.graphemes > 300 || length.bytes > 3000) throw new Error("Posts must contain at most 300 characters and 3,000 UTF-8 bytes.");
  args.assertCurrentAccount?.();
  const richText = new RichText({ text: args.text });
  await richText.detectFacets(createAuthenticatedAppViewAgent(args.session));
  // Unresolved handles remain plain text instead of malformed empty-DID facets.
  const facets = richText.facets?.map(facet => ({
    ...facet,
    features: facet.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")),
  })).filter(facet => facet.features.length);
  args.assertCurrentAccount?.();
  return createOAuthAgent(args.session).post({ text: args.text, ...(facets?.length ? { facets } : {}) });
}
