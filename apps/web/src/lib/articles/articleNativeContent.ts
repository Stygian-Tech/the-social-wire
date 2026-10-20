import { markdownCodeText, markdownHeadingText, parseMarkdownBlocks } from "@stygian/markdown-editor/model";
import { buildArticleNativeContent as buildNativeContent } from "@stygian/anypub-kit/content";
import type { ArticleHost, ArticleImageAsset } from "./articlePublishingTypes";
export { articleRichText } from "@stygian/anypub-kit/content";

/** The app supplies its editor parser; provider conversion is shared by AnyPubKit. */
export function buildArticleNativeContent(host: ArticleHost, markdown: string, assets: ArticleImageAsset[], description = "") {
  return buildNativeContent(host, markdown, assets, description, { parseMarkdownBlocks, markdownHeadingText, markdownCodeText });
}
