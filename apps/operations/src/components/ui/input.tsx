import * as React from "react"
import { cn } from "@/lib/utils"
export function Input({ className, ...props }: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        "h-8 w-full rounded-lg border border-input bg-background/70 px-2.5 text-base shadow-sm transition-colors placeholder:text-muted-foreground hover:bg-background focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-destructive/60 aria-invalid:ring-destructive/20 [@media(pointer:coarse)]:min-h-11 md:text-xs",
        className,
      )}
      {...props}
    />
  )
}
