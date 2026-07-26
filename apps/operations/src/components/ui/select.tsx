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
  onValueChange,
  options,
  value,
}: {
  ariaLabel: string
  className?: string
  onValueChange: (value: string) => void
  options: readonly SelectOption[]
  value: string
}) {
  return (
    <SelectPrimitive.Root items={options} value={value}>
      <SelectPrimitive.Trigger
        aria-label={ariaLabel}
        className={cn(
          "flex h-8 w-full items-center justify-between gap-2 rounded-md border bg-background px-2.5 text-left text-xs hover:bg-muted/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
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
          <SelectPrimitive.Popup className="min-w-[var(--anchor-width)] overflow-hidden rounded-md border bg-popover p-1 text-xs text-popover-foreground shadow-xl data-open:animate-in data-open:fade-in-0 data-open:zoom-in-95">
            <SelectPrimitive.List>
              {options.map((option) => (
                <SelectPrimitive.Item
                  key={option.value}
                  value={option.value}
                  disabled={option.disabled}
                  onClick={() => onValueChange(option.value)}
                  className="relative flex cursor-default select-none items-center rounded-sm py-2 pl-2.5 pr-8 outline-none data-disabled:opacity-50 data-highlighted:bg-muted data-selected:text-primary"
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
