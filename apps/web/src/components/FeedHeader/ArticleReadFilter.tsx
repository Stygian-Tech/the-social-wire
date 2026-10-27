"use client";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

type ArticleReadFilterValue = "all" | "unread";

export function ArticleReadFilter({ value, onChange }: {
  value: ArticleReadFilterValue;
  onChange: (value: ArticleReadFilterValue) => void;
}) {
  return (
    <div role="group" aria-label="Articles Filter" className="flex shrink-0 items-center gap-1">
      {(["all", "unread"] as const).map((option) => (
        <Button
          key={option}
          type="button"
          variant="ghost"
          size="sm"
          aria-pressed={value === option}
          className={cn(
            "relative min-h-11 min-w-11 rounded-md px-2.5 text-[11px] text-muted-foreground after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:rounded-full after:bg-transparent sm:min-h-8",
            value === option && "text-[var(--purple-foreground)] after:bg-primary",
          )}
          onClick={() => onChange(option)}
        >
          {option === "all" ? "All" : "Unread"}
        </Button>
      ))}
    </div>
  );
}
