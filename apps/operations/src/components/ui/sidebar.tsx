"use client"
import * as React from "react"
import { Menu, PanelLeftClose } from "lucide-react"
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
        "sticky top-0 hidden h-[calc(100svh-var(--operations-banner-height,0rem))] shrink-0 flex-col overflow-hidden border-r bg-sidebar transition-[width] md:flex",
        open ? "w-[176px]" : "w-12",
        className,
      )}
    >
      {children}
    </aside>
  )
}
export function SidebarHeader(props: React.HTMLAttributes<HTMLDivElement>) {
  return <div className="flex h-[53.5px] shrink-0 items-center border-b px-3" {...props} />
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
  return <main className={cn("min-h-0 min-w-0 flex-1 overflow-y-auto overscroll-contain", className)} {...props} />
}
export function SidebarNavButton({
  active,
  icon,
  children,
  onClick,
}: {
  active?: boolean
  icon: React.ReactNode
  children: React.ReactNode
  onClick?: () => void
}) {
  const { open } = React.useContext(SidebarContext)
  const button = (
    <button
      onClick={onClick}
      aria-label={open ? undefined : String(children)}
      className={cn(
        "flex h-9 w-full items-center gap-2 rounded-md px-2 text-xs hover:bg-muted",
        active && "bg-sidebar-accent font-medium text-sidebar-accent-foreground",
      )}
    >
      <span className="grid size-5 place-items-center">{icon}</span>
      {open ? <span>{children}</span> : null}
    </button>
  )
  return open ? button : <Tooltip label={children} side="right">{button}</Tooltip>
}
