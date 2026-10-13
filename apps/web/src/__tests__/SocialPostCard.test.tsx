import { describe, expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { SocialPostCard } from "@/components/Social/SocialPostCard";
import { moderateSocialPost } from "@/components/Social/socialModeration";
import { SocialRichText } from "@/components/Social/SocialRichText";

const author = {
  did: "did:plc:other",
  handle: "other.test",
  displayName: "Other",
};
const moderation: ModerationOpts = {
  userDid: "did:plc:viewer",
  prefs: {
    adultContentEnabled: false,
    labels: {},
    labelers: [{ did: "did:plc:labeler", labels: {} }],
    mutedWords: [],
    hiddenPosts: [],
  },
};
function item(
  overrides: Partial<AppBskyFeedDefs.PostView> = {},
): AppBskyFeedDefs.FeedViewPost {
  return {
    post: {
      uri: "at://did:plc:other/app.bsky.feed.post/3abc",
      cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
      author,
      record: {
        $type: "app.bsky.feed.post",
        text: "Visible post",
        createdAt: "2026-10-09T10:00:00.000Z",
      },
      indexedAt: "2026-10-09T10:00:00.000Z",
      ...overrides,
    },
  };
}
function card(value: AppBskyFeedDefs.FeedViewPost, prefs = moderation) {
  return renderToStaticMarkup(
    <SocialPostCard item={value} moderation={prefs} />,
  );
}

describe("Social Post Rendering", () => {
  it("places a compact timestamp in the author header using the post creation time", () => {
    const value = item({ indexedAt: "2026-10-10T12:00:00.000Z" });
    const html = card(value);
    expect(html).toMatch(/datetime="2026-10-09T10:00:00\.000Z"/i);
    expect(html.indexOf("<time")).toBeLessThan(html.indexOf("Visible post"));
    expect(html).toMatch(/<time[^>]*>\d+(s|m|h|d|mo|y)<\/time>/);
    expect(html).toContain("ml-auto self-start shrink-0");
    const detail = renderToStaticMarkup(<SocialPostCard item={value} moderation={moderation} detailedTimestamp />);
    expect(detail.indexOf("<time")).toBeGreaterThan(detail.indexOf("Visible post"));
    expect(detail).toContain(new Date("2026-10-09T10:00:00.000Z").toLocaleString());
  });
  it("renders plain text, attribution and canonical Bluesky links", () => {
    const value = item({
      record: {
        $type: "app.bsky.feed.post",
        text: "<script>alert(1)</script>",
        createdAt: "2026-10-09T10:00:00.000Z",
      },
    });
    value.reason = {
      $type: "app.bsky.feed.defs#reasonRepost",
      by: author,
      indexedAt: "2026-10-09T10:00:00.000Z",
    };
    const html = card(value);
    expect(html).toContain("&lt;script&gt;");
    expect(html).not.toContain("<script>");
    expect(html).toContain("Reposted by Other");
    expect(html).toContain("lucide-repeat-2");
    expect(html.indexOf("Reposted by Other")).toBeLessThan(html.indexOf("Open Profile: Other"));
    expect(html).toContain(
      "https://bsky.app/profile/did%3Aplc%3Aother/post/3abc",
    );
  });
  it("adds a small reply glyph before the author without revealing unavailable or withheld parents", () => {
    const value = item();
    const parent = { ...value.post, $type: "app.bsky.feed.defs#postView" as const };
    value.reply = { root: parent, parent };
    const html = card(value);
    expect(html).toContain("lucide-message-circle");
    expect(html.indexOf("Replying To")).toBeLessThan(html.indexOf("Open Profile: Other"));
    const unavailable = card({ ...value, reply: { root: parent, parent: { $type: "app.bsky.feed.defs#notFoundPost", uri: value.post.uri, notFound: true } } });
    expect(unavailable).toContain("lucide-message-circle");
    expect(unavailable).toContain("Replying To an unavailable post");
    const withheld = card({ ...value, reply: { root: parent, parent: { ...parent, author: { ...author, viewer: { muted: true } } } } });
    expect(withheld).toBe("");
  });
  it("labels record-only replies when feed metadata is missing", () => {
    const value = item();
    value.post.record = { ...value.post.record, reply: {
      parent: { uri: "at://did:plc:parent/app.bsky.feed.post/parent", cid: value.post.cid },
      root: { uri: "at://did:plc:parent/app.bsky.feed.post/root", cid: value.post.cid },
    } };
    const html = card(value);
    expect(html).toContain("Replying To an unavailable post");
    expect(html).toContain("lucide-message-circle");
  });
  it("does not attribute ordinary feed posts to a like or quote", () => {
    const html = card(item());
    expect(html).not.toContain("lucide-heart");
    expect(html).not.toContain("lucide-quote");
    expect(html).not.toContain("Quoted Post");
    const nonPostRecord = card(item({ embed: {
      $type: "app.bsky.embed.record#view",
      record: { $type: "app.bsky.embed.record#viewRecord", uri: "at://did:plc:other/app.bsky.graph.list/abc", cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", author, value: { $type: "app.bsky.graph.list", name: "A List" }, indexedAt: "2026-10-09T10:00:00.000Z" },
    } }));
    expect(nonPostRecord).not.toContain("lucide-quote");
  });
  it("omits blocked posts and withholds muted posts before images load", () => {
    const embed = {
      $type: "app.bsky.embed.images#view",
      images: [
        {
          thumb: "https://example.com/secret.jpg",
          fullsize: "https://example.com/full.jpg",
          alt: "Secret",
        },
      ],
    };
    expect(
      card(
        item({
          author: {
            ...author,
            viewer: {
              blocking: "at://did:plc:viewer/app.bsky.graph.block/abc",
            },
          },
          embed,
        }),
      ),
    ).toBe("");
    const html = card(
      item({ author: { ...author, viewer: { muted: true } }, embed }),
    );
    expect(html).toBe("");
    expect(html).not.toContain("secret.jpg");
    expect(html).not.toContain("Visible post");
  });
  it("withholds adult label media", () => {
    const html = card(
      item({
        labels: [
          {
            src: "did:plc:labeler",
            uri: "at://did:plc:other/app.bsky.feed.post/3abc",
            val: "porn",
            cts: "2026-10-09T10:00:00.000Z",
          },
        ],
        embed: {
          $type: "app.bsky.embed.images#view",
          images: [
            {
              thumb: "https://example.com/adult.jpg",
              fullsize: "https://example.com/full.jpg",
              alt: "Adult",
            },
          ],
        },
      }),
    );
    expect(html).not.toContain("adult.jpg");
  });
  it("moderates a quoted author independently", () => {
    const html = card(
      item({
        embed: {
          $type: "app.bsky.embed.record#view",
          record: {
            $type: "app.bsky.embed.record#viewRecord",
            uri: "at://did:plc:quoted/app.bsky.feed.post/abc",
            cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
            author: {
              did: "did:plc:quoted",
              handle: "quoted.test",
              viewer: { muted: true },
            },
            value: {
              $type: "app.bsky.feed.post",
              text: "Quoted secret",
              createdAt: "2026-10-09T10:00:00.000Z",
            },
            indexedAt: "2026-10-09T10:00:00.000Z",
            embeds: [
              {
                $type: "app.bsky.embed.images#view",
                images: [
                  {
                    thumb: "https://example.com/quoted.jpg",
                    fullsize: "https://example.com/quoted.jpg",
                    alt: "Quoted",
                  },
                ],
              },
            ],
          },
        },
      }),
    );
    expect(html).not.toContain("Quoted secret");
    expect(html).not.toContain("quoted.jpg");
  });
  it("uses UTF-8 facets and refuses unsafe link protocols", () => {
    const record = {
      $type: "app.bsky.feed.post" as const,
      text: "🌎 visit",
      createdAt: "2026-10-09T10:00:00.000Z",
      facets: [
        {
          index: { byteStart: 5, byteEnd: 10 },
          features: [
            {
              $type: "app.bsky.richtext.facet#link",
              uri: "javascript:alert(1)",
            },
          ],
        },
      ],
    };
    const unsafe = renderToStaticMarkup(<SocialRichText record={record} />);
    expect(unsafe).toContain("🌎 ");
    expect(unsafe).toContain("visit");
    expect(unsafe).not.toContain("href=");
    record.facets[0].features[0].uri = "https://example.com/article";
    expect(renderToStaticMarkup(<SocialRichText record={record} />)).toContain(
      'href="https://example.com/article"',
    );
  });
  it("bounds external preview images while preserving the complete image", () => {
    const html = card(item({
      embed: {
        $type: "app.bsky.embed.external#view",
        external: {
          uri: "https://example.com/article",
          title: "An Article",
          description: "Article preview",
          thumb: "https://example.com/preview.png",
        },
      },
    }));
    expect(html).toContain('class="mx-auto block h-auto max-h-60 w-auto max-w-full"');
    expect(html).not.toContain("object-cover");
  });
  it("rejects unsafe external embed and image URLs", () => {
    expect(
      card(
        item({
          embed: {
            $type: "app.bsky.embed.external#view",
            external: {
              uri: "javascript:alert(1)",
              title: "Unsafe",
              description: "Unsafe",
            },
          },
        }),
      ),
    ).not.toContain("Unsafe");
    expect(
      card(
        item({
          embed: {
            $type: "app.bsky.embed.images#view",
            images: [
              {
                thumb: "data:image/svg+xml,unsafe",
                fullsize: "https://example.com/photo.jpg",
                alt: "Unsafe",
              },
            ],
          },
        }),
      ),
    ).not.toContain("<img");
  });
  it("rejects malformed records without rendering them", () => {
    expect(card(item({ record: { $type: "app.bsky.feed.post" } }))).toContain(
      "Post unavailable.",
    );
  });
  it("does not expose malformed blocked posts or crash with muted words", () => {
    const prefs: ModerationOpts = {
      ...moderation,
      prefs: {
        ...moderation.prefs,
        mutedWords: [
          { value: "secret", targets: ["content"], actorTarget: "all" },
        ],
      },
    };
    expect(
      card(
        item({
          author: {
            ...author,
            viewer: {
              blocking: "at://did:plc:viewer/app.bsky.graph.block/abc",
            },
          },
          record: { $type: "app.bsky.feed.post" },
        }),
        prefs,
      ),
    ).toBe("");
    expect(
      card(item({ record: { $type: "app.bsky.feed.post" } }), prefs),
    ).toContain("Post unavailable.");
  });
  it("applies hidden posts and muted words", () => {
    const hidden = {
      ...moderation,
      prefs: { ...moderation.prefs, hiddenPosts: [item().post.uri] },
    };
    expect(card(item(), hidden)).not.toContain("Visible post");
    const muted: ModerationOpts = {
      ...moderation,
      prefs: {
        ...moderation.prefs,
        mutedWords: [
          { value: "Visible", targets: ["content"], actorTarget: "all" },
        ],
      },
    };
    expect(card(item(), muted)).not.toContain("Visible post");
  });
  it("preserves allowed quoted text and image alt text", () => {
    const html = card(
      item({
        embed: {
          $type: "app.bsky.embed.record#view",
          record: {
            $type: "app.bsky.embed.record#viewRecord",
            uri: "at://did:plc:quoted/app.bsky.feed.post/abc",
            cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
            author: { did: "did:plc:quoted", handle: "quoted.test" },
            value: {
              $type: "app.bsky.feed.post",
              text: "Allowed quote",
              createdAt: "2026-10-09T10:00:00.000Z",
            },
            indexedAt: "2026-10-09T10:00:00.000Z",
            embeds: [
              {
                $type: "app.bsky.embed.images#view",
                images: [
                  {
                    thumb: "https://example.com/quoted.jpg",
                    fullsize: "https://example.com/quoted.jpg",
                    alt: "A mountain at sunrise",
                  },
                ],
              },
            ],
          },
        },
      }),
    );
    expect(html).toContain("Allowed quote");
    expect(html).toContain("lucide-quote");
    expect(html.indexOf("Quoted Post")).toBeLessThan(html.indexOf("Open Profile: Other"));
    expect(html).toContain('alt="A mountain at sunrise"');
  });
  it("renders media quotes whose nested record view omits its optional type", () => {
    const embed = {
      $type: "app.bsky.embed.recordWithMedia#view" as const,
      media: { $type: "app.bsky.embed.images#view" as const, images: [{ thumb: "https://example.com/media.jpg", fullsize: "https://example.com/media.jpg", alt: "An outer gallery photo" }] },
      record: { record: {
        $type: "app.bsky.embed.record#viewRecord" as const,
        uri: "at://did:plc:quoted/app.bsky.feed.post/abc",
        cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
        author: { did: "did:plc:quoted", handle: "quoted.test" },
        value: { $type: "app.bsky.feed.post", text: "A quote beside its media", createdAt: "2026-10-09T10:00:00.000Z" },
        indexedAt: "2026-10-09T10:00:00.000Z",
      } },
    };
    const html = card(item({ embed }));
    expect(html).toContain("A quote beside its media");
    expect(html).toContain("lucide-quote");
    expect(html.indexOf("Quoted Post")).toBeLessThan(html.indexOf("Open Profile: Other"));
    expect(html).toContain('alt="An outer gallery photo"');
    expect(html).not.toContain("Attachment unavailable");
    const blocked = card(item({ embed: { ...embed, record: { record: { ...embed.record.record, author: { ...embed.record.record.author, viewer: { blocking: "at://did:plc:viewer/app.bsky.graph.block/abc" } } } } } }));
    expect(blocked).not.toContain("A quote beside its media");
    expect(blocked).not.toContain("media.jpg");
    expect(blocked).not.toContain("lucide-quote");
    const mediaWithheld = card(item({ embed, labels: [{ src: "did:plc:labeler", uri: item().post.uri, val: "porn", cts: "2026-10-09T10:00:00.000Z" }] }));
    expect(mediaWithheld).not.toContain("lucide-quote");
  });

  it("shares safe filtering for malformed records with the timeline", () => {
    const post = item({
      author: {
        ...author,
        viewer: { blocking: "at://did:plc:viewer/app.bsky.graph.block/abc" },
      },
      record: { $type: "app.bsky.feed.post" },
    }).post;
    expect(moderateSocialPost(post, moderation).ui("contentList").filter).toBe(
      true,
    );
    const hidden = {
      ...moderation,
      prefs: { ...moderation.prefs, hiddenPosts: [post.uri] },
    };
    expect(
      moderateSocialPost({ ...post, author }, hidden).ui("contentList").filter,
    ).toBe(true);
  });
});
