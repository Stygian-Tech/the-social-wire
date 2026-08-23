import { cn } from "@/lib/utils";

export function WireAlphaBadge({ className }: { className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex shrink-0 items-center rounded-full border border-[var(--purple-border)] bg-[var(--purple-surface)] px-1.5 py-0.5 text-[9px] font-semibold uppercase leading-none tracking-wide text-[var(--purple-foreground)]",
        className,
      )}
    >
      Alpha
    </span>
  );
}
