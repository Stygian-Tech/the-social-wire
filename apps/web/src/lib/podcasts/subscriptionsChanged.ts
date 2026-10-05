export const PODCAST_SUBSCRIPTIONS_CHANGED_EVENT = "the-social-wire.podcast-subscriptions-changed";

/** Only viewer identity is broadcast; private feed URLs and credentials remain local to the importer. */
export function notifyPodcastSubscriptionsChanged(viewerDid: string): void {
  window.dispatchEvent(new window.CustomEvent(PODCAST_SUBSCRIPTIONS_CHANGED_EVENT, { detail: { viewerDid } }));
}
