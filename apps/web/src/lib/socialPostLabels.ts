import { LABELS, type AppBskyFeedDefs, type InterpretedLabelValueDefinition, type ModerationOpts } from "@atproto/api";

export type SocialPostLabel = { key: string; source: string; self: boolean; definition: InterpretedLabelValueDefinition };

/** Display only active labels with definitions from a subscribed service or the SDK. */
export function socialPostLabels(post: AppBskyFeedDefs.PostView, moderation: ModerationOpts, now = Date.now()): SocialPostLabel[] {
  const labels = [...(post.labels ?? []), ...(post.author.labels ?? [])];
  const latest = new Map<string, typeof labels[number]>();
  for (const label of labels) {
    const key = `${label.src}:${label.uri}:${label.val}`;
    const previous = latest.get(key);
    if (!previous || Date.parse(label.cts) >= Date.parse(previous.cts)) latest.set(key, label);
  }
  const result: SocialPostLabel[] = [];
  for (const [key, label] of latest) {
    if (label.neg || label.val.startsWith("!") || (label.exp && (!Number.isFinite(Date.parse(label.exp)) || Date.parse(label.exp) <= now))) continue;
    const self = label.src === post.author.did;
    if (!self && !moderation.prefs.labelers.some(service => service.did === label.src)) continue;
    const definition = moderation.labelDefs?.[label.src]?.find(item => item.identifier === label.val)
      ?? (Object.hasOwn(LABELS, label.val) ? LABELS[label.val as keyof typeof LABELS] : undefined);
    if (!definition || (self && definition.flags.includes("no-self"))) continue;
    result.push({ key, source: label.src, self, definition });
  }
  return result;
}
