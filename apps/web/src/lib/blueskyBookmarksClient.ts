import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent } from "./blueskySocialClient";

function agentFor(session: OAuthSession, moderation: ModerationOpts) {
  if (session.did !== moderation.userDid) throw new Error("Your account changed. Please reload Bookmarks.");
  const agent = createAuthenticatedAppViewAgent(session);
  agent.configureLabelers(moderation.prefs.labelers.map(labeler => labeler.did));
  return agent;
}
export async function getBlueskyBookmarks({ session, moderation, cursor, signal }: { session: OAuthSession; moderation: ModerationOpts; cursor?: string; signal?: AbortSignal }) {
  return (await agentFor(session, moderation).app.bsky.bookmark.getBookmarks({ limit: 50, cursor }, { signal })).data;
}
export async function setBlueskyBookmark({ session, moderation, uri, cid, saved }: { session: OAuthSession; moderation: ModerationOpts; uri: string; cid: string; saved: boolean }) {
  if (!/^at:\/\/did:[^/?#]+\/app.bsky.feed.post\/[^/?#]+$/.test(uri) || !cid) throw new Error("This bookmark has an invalid post reference.");
  const agent = agentFor(session, moderation);
  if (saved) await agent.app.bsky.bookmark.createBookmark({ uri, cid });
  else await agent.app.bsky.bookmark.deleteBookmark({ uri });
}
