import { RichText } from "@atproto/api";
import { SocialRichText } from "./SocialRichText";

export function SocialComposePreview({ text }: { text: string }) {
  if (!text.trim()) return null;
  // Preview local link/tag facets without looking up people on every keystroke.
  const richText = new RichText({ text });
  richText.detectFacetsWithoutResolution();
  return <section aria-label="Post Preview" className="min-w-0 rounded-xl border bg-muted/20 p-3">
    <p className="mb-2 text-xs font-medium text-muted-foreground">Preview</p>
    <div className="max-h-48 overflow-y-auto">
      <SocialRichText record={{ $type: "app.bsky.feed.post", text, facets: richText.facets, createdAt: "" }} />
    </div>
  </section>;
}
