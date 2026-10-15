import { describe, expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { SocialPostEmbed } from "@/components/Social/SocialPostEmbed";
import { socialExternalGif } from "@/components/Social/socialExternalGif";
import type { ModerationOpts } from "@atproto/api";

const uri = "https://static.klipy.com/ii/example/a.gif?hh=498&ww=280&mp4=video";
const external = { uri, title: "Chef Wok", description: "Alt: Cooking with Fire", thumb: "https://cdn.bsky.app/still.jpg" };
const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };

describe("External GIF embeds", () => {
  it("uses the animated original with retained query and dimensions", () => {
    expect(socialExternalGif(external)).toEqual({ thumb: uri, fullsize: uri, alt: "Cooking with Fire", aspectRatio: { width: 280, height: 498 } });
    const html = renderToStaticMarkup(<SocialPostEmbed embed={{ $type: "app.bsky.embed.external#view", external }} moderation={moderation} />);
    expect(html).toContain("video.mp4");
    expect(html).toContain("still.jpg");
    expect(html).toContain('width="280" height="498"');
    expect(html).toContain("Play GIF");
    expect(html).toContain("Open GIF Viewer");
    expect(html).toContain("object-contain");
    expect(html).not.toContain("object-cover");
  });
  it("uses natural dimensions for absent or invalid hints", () => {
    for (const query of ["", "?ww=Infinity&hh=100", "?ww=-10&hh=100", "?ww=3.5&hh=10", "?ww=100&hh=0"]) {
      expect(socialExternalGif({ ...external, uri: `https://media.example/a.GIF${query}` })?.aspectRatio).toBeUndefined();
    }
  });
  it("supports an animated thumbnail and title fallback", () => {
    expect(socialExternalGif({ ...external, uri: "https://example.com/page", thumb: "https://media.example/animation.gif", description: "" })?.alt).toBe("Chef Wok");
  });
  it("rejects unsafe sources and retains ordinary external cards", () => {
    expect(socialExternalGif({ ...external, uri: "javascript:alert(1)", thumb: "http://media.example/a.gif" })).toBeUndefined();
    expect(socialExternalGif({ ...external, uri: "https://user:secret@media.example/a.gif" })).toBeUndefined();
    const html = renderToStaticMarkup(<SocialPostEmbed embed={{ $type: "app.bsky.embed.external#view", external: { ...external, uri: "https://example.com/story", thumb: "https://media.example/still.jpg" } }} moderation={moderation} />);
    expect(html).toContain("still.jpg");
    expect(html).toContain("Chef Wok");
    expect(html).not.toContain("Open Image");
  });
});
