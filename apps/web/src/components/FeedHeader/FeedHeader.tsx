"use client";

import type { ReactNode } from "react";

import { SidebarTrigger } from "@/components/ui/sidebar";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { appChromeMarginClassName } from "@/components/shared/appChromeStyles";
import { cn } from "@/lib/utils";
import { attachFeedHeaderScrollOverlay } from "./feedHeaderScrollOverlay";

type FeedHeaderProps = {
  title: ReactNode;
  subtitle?: ReactNode;
  mobileStatus?: ReactNode;
  children?: ReactNode;
  className?: string;
  leading?: ReactNode;
};

export function FeedHeader({
  title,
  subtitle,
  mobileStatus,
  children,
  className,
  leading,
}: FeedHeaderProps) {
  return (
    <header
      data-slot="feed-header"
      ref={(header) => header ? attachFeedHeaderScrollOverlay(header) : undefined}
      className={cn(
        floatingGlassClasses,
        appChromeMarginClassName,
        "relative z-20 flex min-h-12 shrink-0 flex-wrap items-center gap-2 px-2 py-1 sm:flex-nowrap sm:gap-2 sm:px-3 md:px-4",
        className,
      )}
    >
      {leading}
      <SidebarTrigger className="h-11 w-11 min-h-[44px] min-w-[44px] shrink-0 -ml-0.5 rounded-md border-0 bg-transparent shadow-none hover:bg-muted/50 aria-expanded:bg-muted/50 sm:h-8 sm:w-8 sm:min-h-0 sm:min-w-0 sm:-ml-1 md:hidden" />
      <div className="flex min-w-0 flex-1 items-center gap-2">
        <div className="mr-auto min-w-0 px-1 sm:px-0">
          <h1 className="truncate text-base font-bold text-foreground">{title}</h1>
          {subtitle ? (
            <p className="truncate text-[11px] text-muted-foreground">{subtitle}</p>
          ) : null}
        </div>
      </div>
      {children ? (
        <div data-slot="feed-header-actions" className="ml-auto flex w-full min-w-0 max-w-full flex-wrap items-center justify-end gap-2 sm:w-auto">
          {children}
        </div>
      ) : null}
      {mobileStatus ? <div className="w-full px-1 pb-1 text-[11px] text-muted-foreground sm:hidden">{mobileStatus}</div> : null}
    </header>
  );
}
