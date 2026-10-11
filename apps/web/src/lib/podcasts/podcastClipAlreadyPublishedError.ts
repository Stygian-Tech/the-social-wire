/** A validated, viewer-owned clip post already exists with other commentary. */
export class PodcastClipAlreadyPublishedError extends Error {
  constructor(public readonly uri: string, public readonly cid: string) {
    super("This clip already has a different published post. Open the existing post before trying again.");
    this.name = "PodcastClipAlreadyPublishedError";
  }
}
