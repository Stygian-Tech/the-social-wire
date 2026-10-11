import { moderateProfile, type ChatBskyActorDefs, type ModerationOpts } from "@atproto/api";

/** Chat bodies and previews must not bypass blocked or hidden participant profiles. */
export function chatProfileSafety(member: ChatBskyActorDefs.ProfileViewBasic | undefined, viewerDid: string, moderation?: ModerationOpts) {
  if (!moderation || moderation.userDid !== viewerDid || !member) return { hidden: true, noOverride: true };
  if (member.did === viewerDid) return { hidden: false, noOverride: false };
  const decision = moderateProfile({ ...member, $type: "app.bsky.actor.defs#profileViewBasic" }, moderation);
  const ui = decision.ui("profileList");
  return { hidden: ui.filter || ui.blur || ui.noOverride, noOverride: ui.noOverride };
}
