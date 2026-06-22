import { cn } from "@/lib/utils";

/** Spacing wrapper so article cards float detached like sidebar rows. */
export const articleListCardWrapperClassName = "w-full px-2 pb-2";

export function articleListCardButtonClassName(options: {
  isSelected?: boolean;
  subdued?: boolean;
}): string {
  return cn(
    "flex w-full flex-col overflow-hidden rounded-2xl border border-border/75 bg-card/88 text-left shadow-[var(--soft-elevation)] backdrop-blur-sm",
    "transition-[border-color,background-color,box-shadow,opacity]",
    "hover:border-[var(--purple-border)] hover:bg-accent/35 hover:[box-shadow:var(--purple-glow-hover)]",
    "dark:border-border/55 dark:bg-card/82 dark:hover:border-[var(--purple-border)] dark:hover:bg-muted/40",
    options.isSelected &&
      "border-[var(--purple-border)] bg-[var(--purple-surface)] shadow-inner ring-1 ring-[var(--purple-border)] dark:bg-[var(--purple-surface)]",
    options.subdued && "opacity-80"
  );
}

/** Read Later / Archive saved-link rows — border only, no card fill. */
export function savedLinkListCardButtonClassName(options: {
  isSelected?: boolean;
}): string {
  return cn(
    "flex w-full flex-col overflow-hidden rounded-2xl border border-border/75 bg-card/75 text-left shadow-[var(--soft-elevation)] backdrop-blur-sm",
    "transition-[border-color,box-shadow,opacity]",
    "hover:border-[var(--purple-border)] hover:[box-shadow:var(--purple-glow-hover)]",
    "dark:border-border/55",
    options.isSelected && "border-[var(--purple-border)] bg-[var(--purple-surface)] ring-1 ring-[var(--purple-border)]",
  );
}
