export { appendLiveArticleContent } from "@stygian/anypub-kit/live-content";

/** Product presentation of one live update; native record preparation is server-owned. */
export function livePostText(text: string, tags: string[]): string {
  const hashtags = tags.map(tag => `#${tag.replace(/^#/, "").replace(/\s/g, "")}`).filter(tag => tag.length > 1);
  return [text.trim(), hashtags.join(" ")].filter(Boolean).join("\n\n");
}
