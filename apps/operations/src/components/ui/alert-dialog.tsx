"use client"
import * as React from "react"
import { Dialog as Primitive } from "@base-ui/react/dialog"
import { cn } from "@/lib/utils"

export const AlertDialog = Primitive.Root
export const AlertDialogTrigger = Primitive.Trigger
export const AlertDialogClose = Primitive.Close
export function AlertDialogTitle({ className, ...props }: Primitive.Title.Props) {
  return <Primitive.Title className={cn("text-sm font-semibold tracking-tight", className)} {...props} />
}
export function AlertDialogDescription({ className, ...props }: Primitive.Description.Props) {
  return <Primitive.Description className={cn("text-xs/relaxed text-muted-foreground", className)} {...props} />
}
export function AlertDialogContent({ className, children, ...props }: Primitive.Popup.Props) {
  return (
    <Primitive.Portal>
      <Primitive.Backdrop className="fixed inset-0 z-50 bg-black/35 backdrop-blur-sm transition-opacity data-ending-style:opacity-0 data-starting-style:opacity-0" />
      <Primitive.Popup
        className={cn(
          "fixed left-1/2 top-1/2 z-50 max-h-[calc(100svh-2rem)] w-[min(92vw,430px)] -translate-x-1/2 -translate-y-1/2 overflow-y-auto overscroll-contain rounded-xl border border-border/60 bg-popover/95 p-4 shadow-2xl supports-backdrop-filter:backdrop-blur-xl",
          className,
        )}
        {...props}
      >
        {children}
      </Primitive.Popup>
    </Primitive.Portal>
  )
}
export function AlertDialogHeader(props: React.HTMLAttributes<HTMLDivElement>) {
  return <div className="grid gap-1.5" {...props} />
}
export function AlertDialogFooter(props: React.HTMLAttributes<HTMLDivElement>) {
  return <div className="mt-4 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end" {...props} />
}
