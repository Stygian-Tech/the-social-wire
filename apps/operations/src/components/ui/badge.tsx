import * as React from "react"
import { cn } from "@/lib/utils"

export function Badge({
  className,
  tone = "neutral",
  ...props
}: React.HTMLAttributes<HTMLSpanElement> & { tone?: "neutral" | "success" | "warning" | "danger" | "info" }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-sm border px-1.5 py-0.5 text-[10px] font-medium",
        tone === "success" && "border-success/30 bg-success-surface text-success",
        tone === "warning" && "border-warning/30 bg-warning-surface text-warning",
        tone === "danger" && "border-destructive/30 bg-danger-surface text-destructive",
        tone === "info" && "border-info/30 bg-info-surface text-info",
        tone === "neutral" && "bg-muted text-muted-foreground",
        className,
      )}
      {...props}
    />
  )
}
