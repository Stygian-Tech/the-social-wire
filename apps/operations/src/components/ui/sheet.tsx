"use client"
import * as React from "react"
import { Dialog as Primitive } from "@base-ui/react/dialog"
import { X } from "lucide-react"
import { cn } from "@/lib/utils"

export const Sheet = Primitive.Root
export const SheetTrigger = Primitive.Trigger
export const SheetClose = Primitive.Close
export function SheetTitle({ className, ...props }: Primitive.Title.Props) {
  return <Primitive.Title className={cn("text-sm font-semibold tracking-tight", className)} {...props} />
}
export function SheetDescription({ className, ...props }: Primitive.Description.Props) {
  return <Primitive.Description className={cn("text-xs/relaxed text-muted-foreground", className)} {...props} />
}
export function SheetContent({ className, children, ...props }: Primitive.Popup.Props) {
  return (
    <Primitive.Portal>
      <Primitive.Backdrop className="fixed inset-0 z-40 bg-black/35 backdrop-blur-sm transition-opacity data-ending-style:opacity-0 data-starting-style:opacity-0" />
      <Primitive.Popup
        className={cn(
          "fixed inset-y-0 right-0 z-50 flex w-[min(94vw,420px)] flex-col border-l border-border/60 bg-popover/96 shadow-2xl transition-transform supports-backdrop-filter:backdrop-blur-xl data-ending-style:translate-x-full data-starting-style:translate-x-full",
          className,
        )}
        {...props}
      >
        {children}
        <Primitive.Close
          aria-label="Close"
          className="absolute right-3 top-3 grid size-8 place-items-center rounded-lg text-muted-foreground transition-colors hover:bg-muted [@media(pointer:coarse)]:size-11"
        >
          <X className="size-4" />
        </Primitive.Close>
      </Primitive.Popup>
    </Primitive.Portal>
  )
}
export function SheetHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("border-b border-border/55 p-3.5", className)} {...props} />
}
export function SheetFooter({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("mt-auto border-t border-border/55 p-3.5", className)} {...props} />
}
