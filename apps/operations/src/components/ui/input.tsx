import * as React from "react"
import { cn } from "@/lib/utils"
export function Input({ className, ...props }: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        "h-8 w-full rounded-md border bg-background px-2.5 text-xs placeholder:text-muted-foreground",
        className,
      )}
      {...props}
    />
  )
}
