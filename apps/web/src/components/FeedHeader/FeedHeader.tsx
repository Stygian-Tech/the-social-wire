import type { ReactNode } from "react";

import { SidebarTrigger } from "@/components/ui/sidebar";

type FeedHeaderProps = {
  title: ReactNode;
  subtitle?: ReactNode;
  children?: ReactNode;
};

export function FeedHeader({ title, subtitle, children }: FeedHeaderProps) {
  return (
    <header className="flex min-h-12 shrink-0 flex-wrap items-center gap-2 border-b border-border/70 bg-background px-2 py-1 sm:flex-nowrap sm:gap-2 sm:px-3 md:px-4">
      <SidebarTrigger className="h-11 w-11 min-h-[44px] min-w-[44px] shrink-0 -ml-0.5 rounded-md border-0 bg-transparent shadow-none hover:bg-muted/50 aria-expanded:bg-muted/50 sm:h-8 sm:w-8 sm:min-h-0 sm:min-w-0 sm:-ml-1 md:hidden" />
      <div className="flex min-w-0 flex-1 items-center gap-2">
        <div className="mr-auto min-w-0 px-1 sm:px-0">
          <h1 className="truncate text-base font-bold text-foreground">{title}</h1>
          {subtitle ? (
            <p className="truncate text-[11px] text-muted-foreground">{subtitle}</p>
          ) : null}
        </div>
        {children}
      </div>
    </header>
  );
}
