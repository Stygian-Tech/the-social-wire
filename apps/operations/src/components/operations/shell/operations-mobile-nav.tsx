"use client"

import { Activity, Menu } from "lucide-react"
import Link from "next/link"
import { useState } from "react"
import { operationsNav } from "@/components/operations/shell/operations-navigation"
import { Button } from "@/components/ui/button"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet"
import { cn } from "@/lib/utils"

export function MobileOperationsNav({ current }: { current: string }) {
  const [open, setOpen] = useState(false)
  const currentLabel = operationsNav.find(([key]) => key === current)?.[1] ?? "Overview"
  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <nav aria-label="Mobile Operations" className="flex h-11 items-center justify-between border-b border-border/55 bg-background/75 px-3 supports-backdrop-filter:backdrop-blur-lg md:hidden">
        <div className="flex min-w-0 items-center gap-2">
          <Activity className="size-3.5 text-primary" />
          <span className="truncate text-xs font-semibold">{currentLabel}</span>
        </div>
        <SheetTrigger render={<Button variant="ghost" size="icon" aria-label="Open Operations Navigation" />}>
          <Menu />
        </SheetTrigger>
      </nav>
      <SheetContent className="w-[min(88vw,320px)]">
        <SheetHeader>
          <div className="flex items-center gap-2">
            <span className="grid size-7 place-items-center rounded-lg bg-primary text-primary-foreground">
              <Activity className="size-4" />
            </span>
            <div>
              <SheetTitle className="text-sm font-semibold">The Social Wire</SheetTitle>
              <SheetDescription className="ops-label">Operations</SheetDescription>
            </div>
          </div>
        </SheetHeader>
        <nav aria-label="Operations" className="grid min-h-0 flex-1 content-start gap-1 overflow-y-auto overscroll-contain p-2">
          {operationsNav.map(([key, label, Icon]) => (
            <Link
              key={key}
              href={key === "overview" ? "/" : `/${key}`}
              onClick={() => setOpen(false)}
              aria-current={current === key ? "page" : undefined}
              className={cn(
                "flex h-9 items-center gap-2 rounded-lg px-2.5 text-xs transition-colors hover:bg-muted [@media(pointer:coarse)]:min-h-11",
                current === key
                  ? "bg-accent font-medium text-accent-foreground"
                  : "text-muted-foreground",
              )}
            >
              <Icon className="size-3.5" />
              {label}
            </Link>
          ))}
        </nav>
      </SheetContent>
    </Sheet>
  )
}
