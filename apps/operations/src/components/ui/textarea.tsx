import * as React from "react"
import { cn } from "@/lib/utils"

export function Textarea({ className, ...props }: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn(
        "min-h-20 w-full resize-y rounded-md border bg-background p-2.5 text-xs placeholder:text-muted-foreground",
        className,
      )}
      {...props}
    />
  )
}
