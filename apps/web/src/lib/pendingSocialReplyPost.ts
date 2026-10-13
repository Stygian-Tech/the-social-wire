/** Local presentation state, never sent to AppView or the viewer's PDS. */
export const PENDING_SOCIAL_REPLY_POST = "app.thesocialwire.ui#pendingPost";

export function isPendingSocialReplyPost(value: unknown): value is { $type: typeof PENDING_SOCIAL_REPLY_POST; uri: string } {
  return !!value && typeof value === "object" && "$type" in value &&
    value.$type === PENDING_SOCIAL_REPLY_POST && "uri" in value && typeof value.uri === "string";
}
