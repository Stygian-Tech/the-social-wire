import { AppBskyFeedPost, AppBskyRichtextFacet, ComAtprotoRepoStrongRef, RichText, type AppBskyFeedDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { postTextLength } from "@/lib/blueskyComposeClient";

export async function publishBrandPost(args: { session: OAuthSession; text: string; parent?: AppBskyFeedDefs.PostView; assertCurrentActor: () => void }) {
  const length = postTextLength(args.text);
  if (!args.text.trim() || length.graphemes > 300 || length.bytes > 3000) throw new Error("Posts Must Contain 1–300 Characters and At Most 3,000 UTF-8 Bytes.");
  let reply;
  if (args.parent) {
    const parent = { uri: args.parent.uri, cid: args.parent.cid };
    const record = AppBskyFeedPost.validateRecord(args.parent.record);
    if (!record.success || !ComAtprotoRepoStrongRef.validateMain(parent).success) throw new Error("The Reply Target Is Unavailable.");
    reply = { parent, root: record.value.reply?.root ?? parent };
    if (!ComAtprotoRepoStrongRef.validateMain(reply.root).success) throw new Error("The Reply Thread Is Invalid.");
  }
  args.assertCurrentActor();
  const rich = new RichText({ text: args.text });
  await rich.detectFacets(createAuthenticatedAppViewAgent(args.session));
  const facets = rich.facets?.map(facet => ({ ...facet, features: facet.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")) })).filter(facet => facet.features.length);
  args.assertCurrentActor();
  const result = await createOAuthAgent(args.session).post({ text: args.text, ...(facets?.length ? { facets } : {}), ...(reply ? { reply } : {}) });
  args.assertCurrentActor();
  return result;
}
