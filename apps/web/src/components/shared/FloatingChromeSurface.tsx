import { createElement, type HTMLAttributes, type Ref } from "react";

import { cn } from "@/lib/utils";
import { floatingGlassClasses } from "./floatingChromeStyles";

type FloatingChromeSurfaceProps = HTMLAttributes<HTMLElement> & {
  as?: "div" | "header" | "aside";
  ref?: Ref<HTMLElement>;
  floating?: boolean;
};

/** Shared material without an extra wrapper, preserving each surface's semantics and ref. */
export function FloatingChromeSurface({
  as = "div",
  floating = true,
  className,
  ...props
}: FloatingChromeSurfaceProps) {
  return createElement(as, {
    ...props,
    className: cn(floating && floatingGlassClasses, className),
  });
}
