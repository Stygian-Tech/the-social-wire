import { AppBskyFeedPost, AppBskyRichtextFacet, ComAtprotoRepoStrongRef, RichText, type AppBskyFeedDefs } from "@atproto/api";
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
  replyTo?: AppBskyFeedDefs.PostView;
  assertCurrentAccount?: () => void;
}): Promise<{ uri: string; cid: string }> {
  if (!args.text.trim()) throw new Error("Write something before posting.");
  const length = postTextLength(args.text);
  if (length.graphemes > 300 || length.bytes > 3000) throw new Error("Posts must contain at most 300 characters and 3,000 UTF-8 bytes.");
  const reply = args.replyTo ? replyReferences(args.replyTo) : undefined;
  args.assertCurrentAccount?.();
  const richText = new RichText({ text: args.text });
  await richText.detectFacets(createAuthenticatedAppViewAgent(args.session));
  // Unresolved handles remain plain text instead of malformed empty-DID facets.
  const facets = richText.facets?.map(facet => ({
    ...facet,
    features: facet.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")),
  })).filter(facet => facet.features.length);
  args.assertCurrentAccount?.();
  return createOAuthAgent(args.session).post({ text: args.text, ...(facets?.length ? { facets } : {}), ...(reply ? { reply } : {}) });
}

function replyReferences(post: AppBskyFeedDefs.PostView): AppBskyFeedPost.ReplyRef {
  if (post.viewer?.replyDisabled) throw new Error("Replies are disabled for this post.");
  const record = AppBskyFeedPost.validateRecord(post.record);
  if (!AppBskyFeedPost.isRecord(post.record) || !record.success) {
    throw new Error("This post cannot be replied to.");
  }
  const parent = { uri: post.uri, cid: post.cid };
  const root = record.value.reply?.root ?? parent;
  for (const reference of [parent, root]) {
    if (!ComAtprotoRepoStrongRef.validateMain(reference).success || !/^at:\/\/did:[^/?#]+\/app\.bsky\.feed\.post\/[^/?#]+$/.test(reference.uri)) {
      throw new Error("This reply requires valid post references.");
    }
  }
  return { root: { uri: root.uri, cid: root.cid }, parent };
}
