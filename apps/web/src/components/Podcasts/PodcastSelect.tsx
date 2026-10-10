"use client";
import type { ComponentProps } from "react";
import { ChevronDown } from "lucide-react";
import { cn } from "@/lib/utils";
/** Native picker with room for long show names and a consistently inset chevron. */
export function PodcastSelect({
  className,
  ...props
}: ComponentProps<"select">) {
  return (
    <span className="relative inline-flex min-w-0 max-w-full">
      <select
        {...props}
        className={cn(
          "min-h-11 min-w-0 max-w-full rounded border bg-background py-2 pl-3",
          className,
          "appearance-none pr-9",
        )}
      />
      <ChevronDown
        aria-hidden="true"
        className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2"
      />
    </span>
  );
}
