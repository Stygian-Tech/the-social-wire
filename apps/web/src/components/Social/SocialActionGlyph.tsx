import { Heart, MessageCircle, Quote, Repeat2, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";

const glyphs: Record<string, { icon: LucideIcon; className?: string }> = {
  like: { icon: Heart, className: "text-rose-600 dark:text-rose-400" },
  "like-via-repost": { icon: Heart, className: "text-rose-600 dark:text-rose-400" },
  reply: { icon: MessageCircle },
  repost: { icon: Repeat2, className: "text-green-600 dark:text-green-400" },
  "repost-via-repost": { icon: Repeat2, className: "text-green-600 dark:text-green-400" },
  quote: { icon: Quote },
};

export function SocialActionGlyph({ reason, className }: { reason: string; className?: string }) {
  const glyph = glyphs[reason];
  if (!glyph) return null;
  const Icon = glyph.icon;
  return <Icon aria-hidden="true" className={cn("size-3 shrink-0 text-muted-foreground", glyph.className, className)} />;
}
