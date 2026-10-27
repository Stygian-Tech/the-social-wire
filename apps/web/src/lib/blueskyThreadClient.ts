import { AppBskyFeedPost } from "@atproto/api";
import { TID } from "@atproto/common-web";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { postTextLength, prepareBlueskyPost } from "./blueskyComposeClient";
import type { ComposeLinkPreview } from "./blueskyExternalEmbed";

type Reference = { uri: string; cid: string };
export type ThreadSegment = { id: string; text: string; linkPreview?: ComposeLinkPreview };
export type ThreadPublication = { did: string; segments: { draft: ThreadSegment; rkey: string; record?: AppBskyFeedPost.Record; attempted?: boolean; result?: Reference }[] };

export function validThreadText(text: string) {
  const { graphemes, bytes } = postTextLength(text);
  return !!text.trim() && graphemes <= 300 && bytes <= 3000;
}

export function newThreadPublication(did: string, segments: ThreadSegment[]): ThreadPublication {
  if (!segments.length || !segments.every(segment => validThreadText(segment.text))) throw new Error("Every Post Needs Text Within the Size Limit.");
  return { did, segments: segments.map(draft => ({ draft: { ...draft }, rkey: TID.nextStr() })) };
}

/** Keep this operation for retries: every segment has one immutable PDS key. */
export async function publishBlueskyThread(args: {
  session: OAuthSession;
  publication: ThreadPublication;
  assertCurrentAccount: () => void;
  onProgress?: (completed: number) => void;
}): Promise<Reference[]> {
  const { publication, session, assertCurrentAccount } = args;
  if (publication.did !== session.did) throw new Error("Your Account Changed. Reopen the Composer.");
  assertCurrentAccount();
  // Resolve and validate each segment independently before creating any records.
  for (const segment of publication.segments) {
    segment.record ??= await prepareBlueskyPost({ session, text: segment.draft.text, linkPreview: segment.draft.linkPreview, assertCurrentAccount });
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
        const result = await agent.com.atproto.repo.createRecord({ repo: session.did, collection: "app.bsky.feed.post", rkey: segment.rkey, record: segment.record! });
        segment.result = { uri: result.data.uri, cid: result.data.cid };
      }
    }
    assertCurrentAccount();
    args.onProgress?.(index + 1);
  }
  return publication.segments.map(segment => segment.result!);
}
