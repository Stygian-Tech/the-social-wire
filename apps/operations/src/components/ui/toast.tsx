"use client"

import { CheckCircle2, CircleAlert, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

export function Toast({
  title,
  description,
  tone = "success",
  onClose,
}: {
  title: string
  description: string
  tone?: "success" | "error"
  onClose: () => void
}) {
  const Icon = tone === "success" ? CheckCircle2 : CircleAlert
  return (
    <div
      role={tone === "error" ? "alert" : "status"}
      aria-live={tone === "error" ? "assertive" : "polite"}
      className="fixed right-4 top-[calc(var(--operations-banner-height,0rem)+1rem)] z-[70] flex w-[min(24rem,calc(100vw-2rem))] items-start gap-3 rounded-lg border bg-popover p-3 shadow-xl"
    >
      <Icon
        className={cn(
          "mt-0.5 size-4 shrink-0",
          tone === "success" ? "text-emerald-600 dark:text-emerald-400" : "text-destructive",
        )}
      />
      <div className="min-w-0 flex-1">
        <p className="text-xs font-semibold">{title}</p>
        <p className="mt-1 text-[10px] leading-4 text-muted-foreground">{description}</p>
      </div>
      <Button
        aria-label="Dismiss Notification"
        variant="ghost"
        size="icon"
        className="-mr-1 -mt-1 size-7"
        onClick={onClose}
      >
        <X />
      </Button>
    </div>
  )
}
