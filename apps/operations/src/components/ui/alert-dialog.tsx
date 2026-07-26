"use client"
import * as React from "react"
import { Dialog as Primitive } from "@base-ui/react/dialog"
import { cn } from "@/lib/utils"

export const AlertDialog = Primitive.Root
export const AlertDialogTrigger = Primitive.Trigger
export const AlertDialogTitle = Primitive.Title
export const AlertDialogDescription = Primitive.Description
export const AlertDialogClose = Primitive.Close
export function AlertDialogContent({ className, children, ...props }: Primitive.Popup.Props) {
  return (
    <Primitive.Portal>
      <Primitive.Backdrop className="fixed inset-0 z-50 bg-black/20 backdrop-blur-[1px]" />
      <Primitive.Popup
        className={cn(
          "fixed left-1/2 top-1/2 z-50 w-[min(92vw,430px)] -translate-x-1/2 -translate-y-1/2 rounded-md border bg-popover p-5 shadow-2xl",
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
  return <div className="mt-5 flex justify-end gap-2" {...props} />
}
