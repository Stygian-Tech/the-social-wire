import { describe, it, expect } from "bun:test";
import {
  feedBrandingFromParsed,
  parseRssFeedXml,
  plainTextRssBodyToHtml,
  rssItemsSortedNewestFirst,
  rssParserItemToDetail,
  rssParserItemToListItem,
} from "@/lib/rssFeedServer";

const MIN_RSS = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Test</title>
    <item>
      <title>Hello</title>
      <link>https://example.com/hello</link>
      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>`;

const RSS_WITH_IMAGE = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Blog</title>
    <link>https://blog.example.com/</link>
    <image>
      <url>https://cdn.example.com/logo.png</url>
      <title>Blog</title>
      <link>https://blog.example.com/</link>
    </image>
    <item>
      <title>Post</title>
      <link>https://blog.example.com/post</link>
      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>`;

const RSS_WITH_FULL_CONTENT = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Full Content</title>
    <item>
      <title>Full post</title>
      <link>https://example.com/full-post</link>
      <description>Short summary only.</description>
      <content:encoded><![CDATA[
        <article><p>Full publisher article body.</p><p>Second paragraph from the feed.</p></article>
      ]]></content:encoded>
      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>`;

describe("rssFeedServer", () => {
  it("extracts channel image and site from parsed feed branding", async () => {
    const parsed = await parseRssFeedXml(RSS_WITH_IMAGE);
    const norm = "https://blog.example.com/feed.xml";
    expect(feedBrandingFromParsed(parsed, norm)).toEqual({
      siteUrl: "https://blog.example.com",
      feedIconUrl: "https://cdn.example.com/logo.png",
    });
  });

  it("parses RSS and maps list rows", async () => {
    const norm = "https://example.com/feed.xml";
    const items = await rssItemsSortedNewestFirst(MIN_RSS);
    expect(items.length).toBe(1);
    const row = rssParserItemToListItem(norm, items[0]!);
    expect(row.title).toBe("Hello");
    expect(row.entryId.startsWith("rssentry:")).toBe(true);
  });

  it("prefers full content:encoded HTML for detail bodies", async () => {
    const norm = "https://example.com/feed.xml";
    const items = await rssItemsSortedNewestFirst(RSS_WITH_FULL_CONTENT);
    const detail = rssParserItemToDetail(norm, items[0]!);

    expect(detail.contentHtml).toContain("Full publisher article body.");
    expect(detail.contentHtml).not.toContain("Short summary only.");
    expect(detail.embedUrl).toBe("https://example.com/full-post");
  });

  it("formats plain RSS bodies into readable paragraphs", () => {
    expect(
      plainTextRssBodyToHtml("First line\nsecond line\n\nSecond paragraph")
    ).toBe("<p>First line<br />second line</p><p>Second paragraph</p>");
  });
});
