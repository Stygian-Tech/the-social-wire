"use client"

import * as React from "react"
import { createPortal } from "react-dom"

type TooltipChildProps = {
  "aria-describedby"?: string
  onBlur?: React.FocusEventHandler<HTMLElement>
  onFocus?: React.FocusEventHandler<HTMLElement>
  onMouseEnter?: React.MouseEventHandler<HTMLElement>
  onMouseLeave?: React.MouseEventHandler<HTMLElement>
}

type TooltipPosition = {
  left: number
  placement: "bottom" | "right" | "top"
  top: number
}

export function Tooltip({
  label,
  children,
  side = "auto",
}: {
  label: React.ReactNode
  children: React.ReactElement<TooltipChildProps>
  side?: "auto" | "right"
}) {
  const descriptionId = React.useId()
  const [position, setPosition] = React.useState<TooltipPosition | null>(null)

  const show = (element: HTMLElement) => {
    const bounds = element.getBoundingClientRect()
    if (side === "right") {
      setPosition({ left: bounds.right + 6, placement: "right", top: bounds.top + bounds.height / 2 })
      return
    }
    const placement = bounds.top < 72 ? "bottom" : "top"
    setPosition({
      left: bounds.left + bounds.width / 2,
      placement,
      top: placement === "top" ? bounds.top - 6 : bounds.bottom + 6,
    })
  }

  const trigger = React.cloneElement(children, {
    "aria-describedby": [children.props["aria-describedby"], descriptionId].filter(Boolean).join(" "),
    onBlur: (event) => {
      children.props.onBlur?.(event)
      setPosition(null)
    },
    onFocus: (event) => {
      children.props.onFocus?.(event)
      show(event.currentTarget)
    },
    onMouseEnter: (event) => {
      children.props.onMouseEnter?.(event)
      show(event.currentTarget)
    },
    onMouseLeave: (event) => {
      children.props.onMouseLeave?.(event)
      setPosition(null)
    },
  })

  return (
    <>
      {trigger}
      {position
        ? createPortal(
            <div
              id={descriptionId}
              role="tooltip"
              className="pointer-events-none fixed z-50 w-max max-w-64 rounded-md border border-border bg-popover px-2.5 py-1.5 text-[11px] leading-relaxed text-popover-foreground shadow-md"
              data-placement={position.placement}
              style={{
                left: position.left,
                top: position.top,
                transform:
                  position.placement === "top"
                    ? "translate(-50%, -100%)"
                    : position.placement === "right"
                      ? "translateY(-50%)"
                      : "translateX(-50%)",
              }}
            >
              {label}
            </div>,
            document.body,
          )
        : null}
    </>
  )
}
