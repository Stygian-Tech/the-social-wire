"use client"

import { Select as SelectPrimitive } from "@base-ui/react/select"
import { Check, ChevronDown } from "lucide-react"
import { cn } from "@/lib/utils"

export type SelectOption = {
  label: string
  value: string
  disabled?: boolean
}

export function Select({
  ariaLabel,
  className,
  id,
  onValueChange,
  options,
  value,
}: {
  ariaLabel: string
  className?: string
  id?: string
  onValueChange: (value: string) => void
  options: readonly SelectOption[]
  value: string
}) {
  return (
    <SelectPrimitive.Root
      items={options}
      value={value}
      onValueChange={(nextValue) => {
        if (typeof nextValue === "string") onValueChange(nextValue)
      }}
    >
      <SelectPrimitive.Trigger
        id={id}
        aria-label={ariaLabel}
        className={cn(
          "flex h-8 w-full items-center justify-between gap-2 rounded-lg border border-input bg-background/70 px-2.5 text-left text-xs shadow-sm transition-colors hover:bg-muted/40 focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-ring/35 [@media(pointer:coarse)]:min-h-11",
          className,
        )}
      >
        <SelectPrimitive.Value />
        <SelectPrimitive.Icon>
          <ChevronDown className="size-3 text-muted-foreground" />
        </SelectPrimitive.Icon>
      </SelectPrimitive.Trigger>
      <SelectPrimitive.Portal>
        <SelectPrimitive.Positioner align="start" sideOffset={4} className="z-[60]">
          <SelectPrimitive.Popup className="min-w-[var(--anchor-width)] overflow-hidden rounded-lg border border-border/60 bg-popover/95 p-1 text-xs text-popover-foreground shadow-xl supports-backdrop-filter:backdrop-blur-xl data-open:animate-in data-open:fade-in-0 data-open:zoom-in-95">
            <SelectPrimitive.List>
              {options.map((option) => (
                <SelectPrimitive.Item
                  key={option.value}
                  value={option.value}
                  disabled={option.disabled}
                  className="relative flex min-h-8 cursor-default select-none items-center rounded-md py-1.5 pl-2.5 pr-8 outline-none data-disabled:opacity-50 data-highlighted:bg-muted data-selected:text-primary [@media(pointer:coarse)]:min-h-11"
                >
                  <SelectPrimitive.ItemText>{option.label}</SelectPrimitive.ItemText>
                  <SelectPrimitive.ItemIndicator className="absolute right-2.5">
                    <Check className="size-3.5" />
                  </SelectPrimitive.ItemIndicator>
                </SelectPrimitive.Item>
              ))}
            </SelectPrimitive.List>
          </SelectPrimitive.Popup>
        </SelectPrimitive.Positioner>
      </SelectPrimitive.Portal>
    </SelectPrimitive.Root>
  )
}
