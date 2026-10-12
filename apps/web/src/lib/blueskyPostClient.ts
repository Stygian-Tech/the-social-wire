import { Agent, ComAtprotoRepoStrongRef, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";

export type SocialEngagementKind = "like" | "repost";
export type SocialPostEngagement = { like?: string; repost?: string; likeCount: number; repostCount: number };

function assertViewer(session: OAuthSession, moderation: ModerationOpts) {
  if (moderation.userDid !== session.did) throw new Error("Your account changed. Please reload this post.");
}

function assertRecordUri(uri: string, collection: string, owner?: string) {
  const match = /^at:\/\/(did:[^/?#]+)\/([^/?#]+)\/([^/?#]+)$/.exec(uri);
  if (!match || match[2] !== collection || (owner && match[1] !== owner)) throw new Error("This post action has an invalid record reference.");
}

export async function getBlueskyPostThread(args: { session: OAuthSession; uri: string; moderation: ModerationOpts; signal?: AbortSignal }) {
  assertViewer(args.session, args.moderation);
  assertRecordUri(args.uri, "app.bsky.feed.post");
  const agent = createAuthenticatedAppViewAgent(args.session);
  agent.configureLabelers(args.moderation.prefs.labelers.map(labeler => labeler.did));
  const response = await agent.app.bsky.feed.getPostThread({ uri: args.uri, depth: 6, parentHeight: 80 }, { signal: args.signal });
  return response.data;
}

/** Writes stay on the viewer's PDS; deletion requires that viewer's exact interaction URI. */
export async function setBlueskyPostEngagement(args: { session: OAuthSession; moderation: ModerationOpts; kind: SocialEngagementKind; uri: string; cid: string; existingUri?: string }) {
  assertViewer(args.session, args.moderation);
  assertRecordUri(args.uri, "app.bsky.feed.post");
  if (args.kind !== "like" && args.kind !== "repost") throw new Error("This post action is invalid.");
  if (!ComAtprotoRepoStrongRef.validateMain({ uri: args.uri, cid: args.cid }).success) throw new Error("This post action requires a valid content reference.");
  const agent = new Agent(args.session);
  if (args.existingUri) {
    assertRecordUri(args.existingUri, `app.bsky.feed.${args.kind}`, args.session.did);
    if (args.kind === "like") await agent.deleteLike(args.existingUri);
    else await agent.deleteRepost(args.existingUri);
    return undefined;
  }
  const result = args.kind === "like" ? await agent.like(args.uri, args.cid) : await agent.repost(args.uri, args.cid);
  assertRecordUri(result.uri, `app.bsky.feed.${args.kind}`, args.session.did);
  return result.uri;
}
