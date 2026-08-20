import * as React from "react"
import { cn } from "@/lib/utils"

export function Textarea({ className, ...props }: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn(
        "min-h-20 w-full resize-y rounded-lg border border-input bg-background/70 p-2.5 text-base shadow-sm transition-colors placeholder:text-muted-foreground hover:bg-background focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-destructive/60 aria-invalid:ring-destructive/20 md:text-xs",
        className,
      )}
      {...props}
    />
  )
}
