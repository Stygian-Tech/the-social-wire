import { compilePostText, resolvePostText } from "@/lib/composePostText";
import { AppBskyFeedPost, ComAtprotoRepoStrongRef, type AppBskyFeedDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { composeExternalEmbed, type ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { postTextLength } from "@/lib/blueskyComposeClient";

export async function publishBrandPost(args: { session: OAuthSession; text: string; linkPreview?: ComposeLinkPreview; parent?: AppBskyFeedDefs.PostView; assertCurrentActor: () => void }) {
  const length = postTextLength(args.text);
  if (!compilePostText(args.text).text.trim() || length.graphemes > 300 || length.bytes > 3000) throw new Error("Posts Must Contain 1–300 Characters and At Most 3,000 UTF-8 Bytes.");
  let reply;
  if (args.parent) {
    const parent = { uri: args.parent.uri, cid: args.parent.cid };
    const record = AppBskyFeedPost.validateRecord(args.parent.record);
    if (!record.success || !ComAtprotoRepoStrongRef.validateMain(parent).success) throw new Error("The Reply Target Is Unavailable.");
    reply = { parent, root: record.value.reply?.root ?? parent };
    if (!ComAtprotoRepoStrongRef.validateMain(reply.root).success) throw new Error("The Reply Thread Is Invalid.");
  }
  args.assertCurrentActor();
  const compiled = await resolvePostText(args.text, createAuthenticatedAppViewAgent(args.session));
  const facets = compiled.facets;
  args.assertCurrentActor();
  const embed = await composeExternalEmbed(args.session, args.text, args.linkPreview, args.assertCurrentActor);
  args.assertCurrentActor();
  const result = await createOAuthAgent(args.session).post({ text: compiled.text, ...(facets?.length ? { facets } : {}), ...(reply ? { reply } : {}), ...(embed ? { embed } : {}) });
  args.assertCurrentActor();
  return result;
}
