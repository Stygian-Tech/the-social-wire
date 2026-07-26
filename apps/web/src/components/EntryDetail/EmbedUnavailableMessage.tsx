import { ExternalLink } from "lucide-react";
import type { ReactNode } from "react";

export function EmbedUnavailableMessage({
  href,
  message,
  linkLabel,
  fallbackContent,
}: {
  href: string;
  message: string;
  linkLabel: string;
  fallbackContent?: ReactNode;
}) {
  const link = (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="mt-3 inline-flex min-h-[44px] items-center gap-1.5 rounded-md py-2 text-sm font-medium text-[var(--purple-foreground)] underline decoration-[var(--purple-border)] underline-offset-4 hover:text-primary hover:decoration-primary"
    >
      <ExternalLink className="size-4 shrink-0" aria-hidden />
      {linkLabel}
    </a>
  );
  if (fallbackContent)
    return (
      <div className="min-h-0 flex-1 overflow-y-auto px-4 py-5 max-md:scroll-pb-[calc(env(safe-area-inset-bottom)+6.25rem)] max-md:pb-[calc(env(safe-area-inset-bottom)+6.25rem)]">
        <div className="mb-5 rounded-xl border border-border bg-muted/35 p-4 text-sm text-muted-foreground">
          <p>{message}</p>
          {link}
        </div>
        {fallbackContent}
      </div>
    );
  return (
    <div className="flex min-h-[200px] flex-col items-center justify-center gap-3 px-4 py-6 text-center text-sm text-muted-foreground">
      <p>{message}</p>
      {link}
    </div>
  );
}
