"use client"
import * as React from "react"
import { Dialog as Primitive } from "@base-ui/react/dialog"
import { X } from "lucide-react"
import { cn } from "@/lib/utils"

export const Sheet = Primitive.Root
export const SheetTrigger = Primitive.Trigger
export const SheetClose = Primitive.Close
export const SheetTitle = Primitive.Title
export const SheetDescription = Primitive.Description
export function SheetContent({ className, children, ...props }: Primitive.Popup.Props) {
  return (
    <Primitive.Portal>
      <Primitive.Backdrop className="fixed inset-0 z-40 bg-black/15 backdrop-blur-[1px] transition-opacity data-ending-style:opacity-0 data-starting-style:opacity-0" />
      <Primitive.Popup
        className={cn(
          "fixed inset-y-0 right-0 z-50 flex w-[min(94vw,390px)] flex-col border-l bg-popover shadow-2xl transition-transform data-ending-style:translate-x-full data-starting-style:translate-x-full",
          className,
        )}
        {...props}
      >
        {children}
        <Primitive.Close
          aria-label="Close"
          className="absolute right-3 top-3 rounded-md p-1 text-muted-foreground hover:bg-muted"
        >
          <X className="size-4" />
        </Primitive.Close>
      </Primitive.Popup>
    </Primitive.Portal>
  )
}
export function SheetHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("border-b p-4", className)} {...props} />
}
export function SheetFooter({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("mt-auto border-t p-4", className)} {...props} />
}
