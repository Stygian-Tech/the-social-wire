import { expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AppBskyEmbedExternal, ModerationOpts } from "@atproto/api";
import { socialYouTubePlayerUrl } from "@/components/Social/socialYouTubePlayerUrl";
import { SocialPostCard } from "@/components/Social/SocialPostCard";

const id = "dQw4w9WgXcQ";
const player = `https://www.youtube-nocookie.com/embed/${id}`;
const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
function card(uri: string, blocked = false, quote = false) {
  const embed: AppBskyEmbedExternal.View & { $type: "app.bsky.embed.external#view" } = { $type: "app.bsky.embed.external#view", external: { uri, title: "A YouTube Video", description: "Video description" } };
  const author = { did: "did:plc:other", handle: "other.test", ...(blocked ? { viewer: { blockedBy: true } } : {}) };
  const record = { $type: "app.bsky.feed.post", text: "Watch this", createdAt: "2026-10-10T00:00:00Z" };
  return renderToStaticMarkup(<SocialPostCard moderation={moderation} item={{ post: { uri: "at://did:plc:other/app.bsky.feed.post/one", cid: "cid", author, record, indexedAt: record.createdAt, embed: quote ? { $type: "app.bsky.embed.record#view", record: { $type: "app.bsky.embed.record#viewRecord", uri: "at://did:plc:other/app.bsky.feed.post/two", cid: "cid", author, value: record, indexedAt: record.createdAt, embeds: [embed] } } : embed } }} />);
}

it("recognizes watch, shortened, Shorts, live and embedded YouTube videos", () => {
  for (const uri of [`https://www.youtube.com/watch?v=${id}&si=tracking`, `https://youtube.com/watch?v=${id}`, `https://m.youtube.com/watch?v=${id}`, `https://music.youtube.com/watch?v=${id}`, `https://youtu.be/${id}?si=tracking`, `https://www.youtube.com/shorts/${id}`, `https://www.youtube.com/live/${id}`, player]) expect(socialYouTubePlayerUrl(uri)).toBe(player);
  expect(socialYouTubePlayerUrl(`https://youtu.be/${id}?t=1h2m3s`)).toBe(`${player}?start=3723`);
  expect(socialYouTubePlayerUrl(`https://youtube.com/watch?v=${id}&t=90`)).toBe(`${player}?start=90`);
});

it("rejects lookalike hosts, credentials, unsafe protocols, non-video paths and invalid IDs", () => {
  for (const uri of [`https://youtube.com.evil.test/watch?v=${id}`, `https://evil.test/watch?v=${id}`, `https://youtube.com@evil.test/watch?v=${id}`, `https://user:password@youtube.com/watch?v=${id}`, `http://youtube.com/watch?v=${id}`, `https://youtube.com:444/watch?v=${id}`, "https://youtube.com/playlist?list=one", "https://youtube.com/watch?v=bad", `https://youtu.be/${id}/extra`, "https://youtube.com/embed/%22onload%3Dalert(1)"]) expect(socialYouTubePlayerUrl(uri)).toBeUndefined();
});

it("renders a responsive player with a referrer and a separate YouTube fallback link", () => {
  const element = document.createElement("div"); element.innerHTML = card(`https://youtu.be/${id}`);
  const iframe = element.querySelector("iframe")!;
  expect(iframe.getAttribute("src")).toBe(player);
  expect(iframe.getAttribute("title")).toBe("A YouTube Video");
  expect(iframe.getAttribute("referrerpolicy")).toBe("strict-origin-when-cross-origin");
  expect(iframe.className).toContain("aspect-video");
  expect(iframe.hasAttribute("allowfullscreen")).toBe(true);
  expect(iframe.closest("a")).toBeNull();
  expect(element.textContent).toContain("Open On YouTube");
});

it("supports quoted YouTube attachments and preserves blocked media and ordinary link previews", () => {
  expect(card(`https://youtu.be/${id}`, false, true)).toContain(player);
  expect(card(`https://youtu.be/${id}`, true)).not.toContain("<iframe");
  expect(card("https://example.com/article")).not.toContain("<iframe");
  expect(card("https://example.com/article")).toContain("Video description");
});
