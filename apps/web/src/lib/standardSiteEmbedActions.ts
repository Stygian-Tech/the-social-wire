import type { StandardSiteEmbed } from "./standardSiteEmbedClient";

type ViewerRecords = {
  subscriptions: Array<{ uri: string; value: { publication: string } }>;
  recommendations: Array<{ uri: string; value: { document: string } }>;
};

/** Re-read before deciding whether to create or delete; another surface may have changed the records. */
export async function performStandardSiteArticleAction(options: {
  kind: "subscription" | "recommendation";
  metadata: StandardSiteEmbed;
  remove: boolean;
  assertSession: () => void;
  readViewer: () => Promise<ViewerRecords>;
  subscribe: () => Promise<unknown>;
  unsubscribe: (uri: string) => Promise<unknown>;
  recommend: () => Promise<unknown>;
  unrecommend: (uri: string) => Promise<unknown>;
}) {
  options.assertSession();
  const viewer = await options.readViewer();
  options.assertSession();
  const subscription = options.kind === "subscription";
  const matching = subscription
    ? viewer.subscriptions.filter(row => row.value.publication === options.metadata.publicationUri)
    : viewer.recommendations.filter(row => row.value.document === options.metadata.documentUri);
  if (!options.remove) {
    if (!matching.length) await (subscription ? options.subscribe() : options.recommend());
    return;
  }
  for (const record of matching) {
    options.assertSession();
    await (subscription ? options.unsubscribe(record.uri) : options.unrecommend(record.uri));
  }
}
