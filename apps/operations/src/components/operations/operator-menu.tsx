"use client"

import { Menu } from "@base-ui/react/menu"
import { ChevronDown, LogOut } from "lucide-react"
import { useState } from "react"

export function OperatorMenu({ operator, onSignOut }: { operator: string; onSignOut: () => Promise<void> }) {
  const [signingOut, setSigningOut] = useState(false)

  const signOut = async () => {
    setSigningOut(true)
    try {
      await onSignOut()
    } finally {
      setSigningOut(false)
    }
  }

  return (
    <Menu.Root>
      <Menu.Trigger
        aria-label="Operator Menu"
        className="flex min-h-11 items-center gap-2 rounded-md border-l py-1 pl-2 pr-1 text-left outline-none transition-colors hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring md:pl-3"
      >
        <span className="grid size-7 place-items-center rounded-full bg-primary text-[10px] text-primary-foreground">
          OP
        </span>
        <span className="hidden max-w-32 md:block">
          <span className="block truncate text-[10px] font-medium">Operator</span>
          <span className="block truncate text-[9px] text-muted-foreground">{operator}</span>
        </span>
        <ChevronDown className="size-3 text-muted-foreground" />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner align="end" sideOffset={6} className="z-50 outline-none">
          <Menu.Popup className="min-w-48 rounded-md border bg-popover p-1 text-popover-foreground shadow-md outline-none data-open:animate-in data-open:fade-in-0 data-open:zoom-in-95">
            <div className="border-b px-2 py-1.5">
              <p className="text-[10px] font-medium">Operator</p>
              <p className="max-w-56 truncate text-[9px] text-muted-foreground">{operator}</p>
            </div>
            <Menu.Item
              disabled={signingOut}
              onClick={() => void signOut()}
              className="mt-1 flex min-h-11 cursor-default items-center gap-2 rounded-sm px-2 py-1.5 text-xs text-destructive outline-none select-none focus:bg-destructive/10 data-disabled:pointer-events-none data-disabled:opacity-50"
            >
              <LogOut className="size-3.5" />
              {signingOut ? "Logging Out…" : "Log Out"}
            </Menu.Item>
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  )
}
