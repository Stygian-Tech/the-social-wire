import { cn } from "@/lib/utils";

/** Spacing wrapper so article cards float detached like sidebar rows. */
export const articleListCardHorizontalWrapperClassName = "w-full px-2";
export const articleListCardWrapperClassName =
  `${articleListCardHorizontalWrapperClassName} pb-2`;

export function articleListCardButtonClassName(options: {
  isSelected?: boolean;
  subdued?: boolean;
}): string {
  return cn(
    "flex w-full flex-col overflow-hidden rounded-2xl border border-border/75 bg-card/88 text-left shadow-[var(--soft-elevation)] backdrop-blur-sm",
    "transition-[border-color,background-color,box-shadow,opacity]",
    "hover:border-[var(--purple-border)] hover:bg-muted/45 hover:[box-shadow:var(--purple-glow-hover)]",
    "dark:border-border/55 dark:bg-card/82 dark:hover:border-[var(--purple-border)] dark:hover:bg-muted/40",
    options.isSelected &&
      "border-[var(--purple-border)] bg-[var(--purple-surface)] ring-1 ring-[var(--purple-border)] [box-shadow:var(--purple-glow-selected)] dark:bg-[var(--purple-surface)]",
    options.subdued && "opacity-80"
  );
}

/** Compact horizontal article row inspired by L@tr Link's saved-item list. */
export function articleListRowButtonClassName(options: {
  isSelected?: boolean;
  subdued?: boolean;
}): string {
  return cn(
    "relative grid w-full grid-cols-[5.5rem_minmax(0,1fr)] gap-3 overflow-hidden rounded-lg border border-border/75 bg-card/88 p-2.5 text-left shadow-sm backdrop-blur-sm sm:grid-cols-[6rem_minmax(0,1fr)]",
    "transition-[border-color,background-color,box-shadow,opacity]",
    "hover:border-[var(--purple-border)] hover:bg-muted/35 hover:[box-shadow:var(--purple-glow-hover)]",
    "dark:border-border/55 dark:bg-card/82 dark:hover:border-[var(--purple-border)] dark:hover:bg-muted/30",
    options.isSelected &&
      "border-[var(--purple-border)] bg-[var(--purple-surface)] ring-1 ring-[var(--purple-border)] [box-shadow:var(--purple-glow-selected)] dark:bg-[var(--purple-surface)]",
    options.subdued && "opacity-80",
  );
}

/** Read Later / Archive saved-link rows — border only, no card fill. */
export function savedLinkListCardButtonClassName(options: {
  isSelected?: boolean;
}): string {
  return cn(
    "flex w-full flex-col overflow-hidden rounded-2xl border border-border/75 bg-card/75 text-left shadow-[var(--soft-elevation)] backdrop-blur-sm",
    "transition-[border-color,box-shadow,opacity]",
    "hover:border-[var(--purple-border)] hover:bg-muted/35 hover:[box-shadow:var(--purple-glow-hover)]",
    "dark:border-border/55",
    options.isSelected && "border-[var(--purple-border)] bg-[var(--purple-surface)] ring-1 ring-[var(--purple-border)] [box-shadow:var(--purple-glow-selected)]",
  );
}
