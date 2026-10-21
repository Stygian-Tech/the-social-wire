import { hashKey } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import type { SocialFeed } from "./blueskySocialClient";

export function socialLabelerDids(moderation: ModerationOpts | undefined): string[] | undefined {
  return moderation && [...new Set(moderation.prefs.labelers.map(labeler => labeler.did))].sort();
}

/** Includes every safety input that validated catalog names, avatars, and posts. */
export function socialModerationScope(moderation: ModerationOpts | undefined): string {
  return hashKey([moderation?.userDid, moderation && {
    ...moderation.prefs,
    labelers: [...moderation.prefs.labelers].sort((a, b) => a.did.localeCompare(b.did)),
  }, moderation?.labelDefs]);
}

export function socialTimelineKey(did: string, feed: SocialFeed, moderation: ModerationOpts | undefined) {
  return ["blueskySocial", did, "timeline", "cache-v1", feed.kind, feed.uri, socialLabelerDids(moderation)];
}
