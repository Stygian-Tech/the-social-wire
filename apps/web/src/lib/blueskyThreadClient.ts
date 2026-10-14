import { AppBskyFeedPost } from "@atproto/api";
import { TID } from "@atproto/common-web";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { postTextLength, prepareBlueskyPost } from "./blueskyComposeClient";
import type { ComposeLinkPreview } from "./blueskyExternalEmbed";
import type { ComposerMedia } from "./composerMedia";
import { mediaHasContent, mediaReady } from "./composerMedia";
import type { AppBskyFeedDefs } from "@atproto/api";

type Reference = { uri: string; cid: string };
export type ThreadSegment = { id: string; text: string; removedLinkUrl?: string; linkPreview?: ComposeLinkPreview; media?: ComposerMedia; replyTo?: AppBskyFeedDefs.PostView; quoteTo?: AppBskyFeedDefs.PostView };
export type ThreadPublication = { did: string; segments: { draft: ThreadSegment; rkey: string; record?: AppBskyFeedPost.Record; attempted?: boolean; result?: Reference }[] };

export function validThreadText(text: string, media?: ComposerMedia) {
  const { graphemes, bytes } = postTextLength(text);
  return (!!text.trim() || mediaHasContent(media)) && mediaReady(media) && graphemes <= 300 && bytes <= 3000;
}

export function newThreadPublication(did: string, segments: ThreadSegment[]): ThreadPublication {
  if (!segments.length || !segments.every(segment => validThreadText(segment.text, segment.media))) throw new Error("Every Post Needs Text Or Ready Media Within The Size Limit.");
  return { did, segments: segments.map(draft => ({ draft: { ...draft }, rkey: TID.nextStr() })) };
}

/** Keep this operation for retries: every segment has one immutable PDS key. */
export async function publishBlueskyThread(args: {
  session: OAuthSession;
  publication: ThreadPublication;
  assertCurrentAccount: () => void;
  onProgress?: (completed: number) => void;
  onMediaProgress?: (message: string) => void;
  checkpoint?: () => Promise<void>;
}): Promise<Reference[]> {
  const { publication, session, assertCurrentAccount } = args;
  if (publication.did !== session.did) throw new Error("Your Account Changed. Reopen the Composer.");
  assertCurrentAccount();
  // Resolve and validate each segment independently before creating any records.
  for (const [index, segment] of publication.segments.entries()) {
    segment.record ??= await prepareBlueskyPost({ session, ...segment.draft, assertCurrentAccount, onMediaProgress: message => args.onMediaProgress?.(`Post ${index + 1}: ${message}`) });
    await args.checkpoint?.();
  }
  const agent = createOAuthAgent(session);
  for (let index = 0; index < publication.segments.length; index++) {
    const segment = publication.segments[index];
    assertCurrentAccount();
    if (!segment.result) {
      if (index > 0) segment.record!.reply = { root: publication.segments[0].result!, parent: publication.segments[index - 1].result! };
      // A previous timeout can have committed the record. Read that exact key first,
      // and fail closed on errors other than confirmed absence.
      if (segment.attempted) {
        try {
          const existing = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: "app.bsky.feed.post", rkey: segment.rkey });
          assertCurrentAccount();
          const expected = (await cidForLex(lexParse(JSON.stringify(segment.record), { strict: true }))).toString();
          if (existing.data.cid !== expected) throw new Error("A Thread Post Changed on Your PDS. Review It Before Retrying.");
          segment.result = { uri: existing.data.uri, cid: existing.data.cid };
        } catch (error) {
          if (!(error && typeof error === "object" && "error" in error && error.error === "RecordNotFound")) throw error;
        }
      }
      if (!segment.result) {
        assertCurrentAccount();
        segment.attempted = true;
        await args.checkpoint?.();
        assertCurrentAccount();
        const result = await agent.com.atproto.repo.createRecord({ repo: session.did, collection: "app.bsky.feed.post", rkey: segment.rkey, record: segment.record! });
        segment.result = { uri: result.data.uri, cid: result.data.cid };
      }
    }
    assertCurrentAccount();
    await args.checkpoint?.();
    args.onProgress?.(index + 1);
  }
  return publication.segments.map(segment => segment.result!);
}
