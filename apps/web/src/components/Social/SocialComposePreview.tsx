import { compilePostText } from "@/lib/composePostText";
import { SocialRichText } from "./SocialRichText";

export function SocialComposePreview({ text }: { text: string }) {
  const compiled = compilePostText(text);
  if (!compiled.text.trim()) return null;
  return <section aria-label="Post Preview" className="min-w-0 rounded-xl border bg-muted/20 p-3">
    <p className="mb-2 text-xs font-medium text-muted-foreground">Preview</p>
    <div className="max-h-48 overflow-y-auto">
      <SocialRichText markdown={false} record={{ $type: "app.bsky.feed.post", text: compiled.text, facets: compiled.facets, createdAt: "" }} />
    </div>
  </section>;
}
