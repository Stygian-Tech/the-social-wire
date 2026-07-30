import { cn } from "@/lib/utils";

interface ArticleContentProps {
  html: string;
  className?: string;
}

export function ArticleContent({ html, className }: ArticleContentProps) {
  return (
    <div
      className={cn("article-content flow-root", className)}
      // Safe: content is normalized and sanitized before rendering.
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
