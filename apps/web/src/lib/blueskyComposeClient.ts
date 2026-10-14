import { AppBskyFeedPost, AppBskyRichtextFacet, ComAtprotoRepoStrongRef, RichText, type AppBskyEmbedRecord, type AppBskyFeedDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { composeExternalEmbed, type ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { composeMediaEmbed } from "./blueskyMediaEmbed";
import { mediaHasContent, mediaReady, type ComposerMedia } from "./composerMedia";
import type { ThreadPublication } from "./blueskyThreadClient";

export function postTextLength(text: string): { graphemes: number; bytes: number } {
  return { graphemes: new RichText({ text }).graphemeLength, bytes: new TextEncoder().encode(text).length };
}

export type BlueskyPostInput = {
  session: OAuthSession;
  text: string;
  linkPreview?: ComposeLinkPreview;
  media?: ComposerMedia;
  onMediaProgress?: (message: string) => void;
  publication?: ThreadPublication;
  checkpoint?: () => Promise<void>;
  replyTo?: AppBskyFeedDefs.PostView;
  quoteTo?: AppBskyFeedDefs.PostView;
  assertCurrentAccount?: () => void;
};

/** Called only by an explicit Post action; validation precedes all network requests. */
export async function createBlueskyPost(args: BlueskyPostInput): Promise<{ uri: string; cid: string }> {
  if (args.publication) {
    const { publishBlueskyThread } = await import("./blueskyThreadClient");
    const results = await publishBlueskyThread({ session: args.session, publication: args.publication, assertCurrentAccount: args.assertCurrentAccount ?? (() => {}), checkpoint: args.checkpoint, onMediaProgress: args.onMediaProgress });
    return results[0];
  }
  const record = await prepareBlueskyPost(args);
  args.assertCurrentAccount?.();
  return createOAuthAgent(args.session).post(record);
}

export async function prepareBlueskyPost(args: BlueskyPostInput): Promise<AppBskyFeedPost.Record> {
  if (!args.text.trim() && !mediaHasContent(args.media)) throw new Error("Write Something Or Add Media Before Posting.");
  if (!mediaReady(args.media)) throw new Error("Finish Preparing Attachments Before Posting");
  if (args.media && args.linkPreview) throw new Error("Choose Media Or A Link Preview");
  const length = postTextLength(args.text);
  if (length.graphemes > 300 || length.bytes > 3000) throw new Error("Posts must contain at most 300 characters and 3,000 UTF-8 bytes.");
  if (args.replyTo && args.quoteTo) throw new Error("Choose either a reply or a quote post.");
  const reply = args.replyTo ? replyReferences(args.replyTo) : undefined;
  const quote = args.quoteTo ? quoteEmbed(args.quoteTo) : undefined;
  args.assertCurrentAccount?.();
  const richText = new RichText({ text: args.text });
  await richText.detectFacets(createAuthenticatedAppViewAgent(args.session));
  // Unresolved handles remain plain text instead of malformed empty-DID facets.
  const facets = richText.facets?.map(facet => ({
    ...facet,
    features: facet.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")),
  })).filter(facet => facet.features.length);
  args.assertCurrentAccount?.();
  const external = args.media ? await composeMediaEmbed(args.session, args.media, args.assertCurrentAccount, args.onMediaProgress) : await composeExternalEmbed(args.session, args.text, args.linkPreview, args.assertCurrentAccount);
  const embed = quote && external ? { $type: "app.bsky.embed.recordWithMedia" as const, record: quote, media: external } : quote ?? external;
  args.assertCurrentAccount?.();
  return { $type: "app.bsky.feed.post", createdAt: new Date().toISOString(), text: args.text, ...(facets?.length ? { facets } : {}), ...(reply ? { reply } : {}), ...(embed ? { embed } : {}) };
}

function quoteEmbed(post: AppBskyFeedDefs.PostView): AppBskyEmbedRecord.Main & { $type: "app.bsky.embed.record" } {
  if (post.viewer?.embeddingDisabled) throw new Error("Quotes are disabled for this post.");
  const record = { uri: post.uri, cid: post.cid };
  if (!ComAtprotoRepoStrongRef.validateMain(record).success || !/^at:\/\/did:[^/?#]+\/app\.bsky\.feed\.post\/[^/?#]+$/.test(record.uri)) {
    throw new Error("This quote requires a valid post reference.");
  }
  return { $type: "app.bsky.embed.record", record };
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
