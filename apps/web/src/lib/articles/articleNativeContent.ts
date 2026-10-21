import { markdownCodeText, markdownHeadingText, parseMarkdownBlocks } from "@stygian/markdown-editor/model";
import { buildArticleNativeContent as buildNativeContent } from "@stygian/anypub-kit/content";
import type { ArticleHost, ArticleImageAsset } from "./articlePublishingTypes";
import type { PreparationOptions } from "@stygian/anypub-kit";

/** The app supplies its editor parser; provider conversion is shared by AnyPubKit. */
export function buildArticleNativeContent(host: ArticleHost, markdown: string, assets: ArticleImageAsset[], description = "", options?: PreparationOptions) {
  return buildNativeContent({ host, markdown, assets, description, blocks: parseMarkdownBlocks(markdown).map(block => ({ ...block, source: block.kind === "heading" ? markdownHeadingText(block.source) : block.kind === "code" ? markdownCodeText(block.source) : block.source })) }, options);
}
