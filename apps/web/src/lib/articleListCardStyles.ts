import { cn } from "@/lib/utils";

/** Spacing wrapper so article cards float detached like sidebar rows. */
export const articleListCardWrapperClassName = "w-full px-2 pb-1.5";

export function articleListCardButtonClassName(options: {
  isSelected?: boolean;
  subdued?: boolean;
}): string {
  return cn(
    "flex w-full flex-col overflow-hidden rounded-lg border border-border/70 bg-muted/30 text-left shadow-sm backdrop-blur-sm",
    "transition-[border-color,background-color,box-shadow,opacity]",
    "hover:border-border hover:bg-muted/50 hover:shadow-md hover:[box-shadow:var(--purple-glow-hover)]",
    "dark:border-border/55 dark:bg-muted/20 dark:hover:border-border dark:hover:bg-muted/40",
    options.isSelected &&
      "border-border/90 bg-muted/65 shadow-inner ring-1 ring-border/30 dark:bg-muted/45",
    options.subdued && "opacity-80"
  );
}
