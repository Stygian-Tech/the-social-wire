"use client"
import * as React from "react"
import { Menu, PanelLeftClose } from "lucide-react"
import Link from "next/link"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { Tooltip } from "@/components/ui/tooltip"

const SidebarContext = React.createContext<{ open: boolean; setOpen: (open: boolean) => void }>({
  open: true,
  setOpen: () => {},
})
export function SidebarProvider({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = React.useState(true)
  return (
    <SidebarContext.Provider value={{ open, setOpen }}>
      <div className="flex h-[calc(100svh-var(--operations-banner-height,0rem))] min-h-0 min-w-0 overflow-hidden">
        {children}
      </div>
    </SidebarContext.Provider>
  )
}
export function Sidebar({ className, children }: React.HTMLAttributes<HTMLElement>) {
  const { open } = React.useContext(SidebarContext)
  return (
    <aside
      className={cn(
        "sticky top-0 hidden h-[calc(100svh-var(--operations-banner-height,0rem))] shrink-0 flex-col overflow-hidden border-r border-sidebar-border/70 bg-sidebar/88 transition-[width] supports-backdrop-filter:bg-sidebar/72 supports-backdrop-filter:backdrop-blur-xl md:flex",
        open ? "w-[176px]" : "w-12",
        className,
      )}
    >
      {children}
    </aside>
  )
}
export function SidebarHeader(props: React.HTMLAttributes<HTMLDivElement>) {
  return <div className="flex h-12 shrink-0 items-center border-b border-sidebar-border/70 px-3" {...props} />
}
export function SidebarContent(props: React.HTMLAttributes<HTMLDivElement>) {
  return <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-2" {...props} />
}
export function SidebarFooter(props: React.HTMLAttributes<HTMLDivElement>) {
  return <div className="shrink-0 border-t p-2" {...props} />
}
export function SidebarTrigger() {
  const { open, setOpen } = React.useContext(SidebarContext)
  return (
    <Button
      variant="ghost"
      size="icon"
      onClick={() => setOpen(!open)}
      aria-label={open ? "Collapse Sidebar" : "Expand Sidebar"}
    >
      {open ? <PanelLeftClose /> : <Menu />}
    </Button>
  )
}
export function SidebarInset({ className, ...props }: React.HTMLAttributes<HTMLElement>) {
  return <main className={cn("min-h-0 min-w-0 flex-1 overflow-y-auto overscroll-contain scroll-smooth", className)} {...props} />
}
export function SidebarNavButton({
  active,
  href,
  icon,
  children,
}: {
  active?: boolean
  href: string
  icon: React.ReactNode
  children: React.ReactNode
}) {
  const { open } = React.useContext(SidebarContext)
  const button = (
    <Link
      href={href}
      aria-current={active ? "page" : undefined}
      aria-label={open ? undefined : String(children)}
      className={cn(
        "flex h-8 w-full items-center gap-2 rounded-md px-2 text-xs transition-colors hover:bg-sidebar-accent/70 [@media(pointer:coarse)]:min-h-11",
        active && "bg-sidebar-accent font-medium text-sidebar-accent-foreground",
      )}
    >
      <span className="grid size-5 place-items-center">{icon}</span>
      {open ? <span>{children}</span> : null}
    </Link>
  )
  return open ? button : <Tooltip label={children} side="right">{button}</Tooltip>
}
