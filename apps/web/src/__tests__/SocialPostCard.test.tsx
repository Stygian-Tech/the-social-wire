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
      cid: "bafyreia",
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
    expect(html).toContain(
      "https://bsky.app/profile/did%3Aplc%3Aother/post/3abc",
    );
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
            cid: "bafyreia",
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
            cid: "bafyreia",
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
    expect(html).toContain('alt="An outer gallery photo"');
    expect(html).not.toContain("Attachment unavailable");
    const blocked = card(item({ embed: { ...embed, record: { record: { ...embed.record.record, author: { ...embed.record.record.author, viewer: { blocking: "at://did:plc:viewer/app.bsky.graph.block/abc" } } } } } }));
    expect(blocked).not.toContain("A quote beside its media");
    expect(blocked).not.toContain("media.jpg");
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
