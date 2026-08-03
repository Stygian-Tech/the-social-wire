"use client";

import Image from "next/image";

import iconSrc from "@/app/icon.png";
import { SidebarHeader } from "@/components/ui/sidebar";

export function AppSidebarBrandHeader() {
  return (
    <SidebarHeader className="px-2 py-3">
      <div className="grid min-w-0 grid-cols-[1.5rem_auto_minmax(0,1fr)] items-center gap-x-1.5">
        <Image
          src={iconSrc}
          alt=""
          width={24}
          height={24}
          className="col-start-1 row-start-1 shrink-0 rounded"
        />
        <span className="col-start-2 whitespace-nowrap text-[13px] font-bold leading-tight tracking-[-0.02em] text-sidebar-foreground">
          The Social Wire
        </span>
        <span className="col-start-3 inline-flex w-fit items-center rounded-full border border-[var(--purple-border)] bg-primary/10 px-1.5 py-0.5 text-[10px] font-bold leading-none text-[var(--purple-foreground)]">
          Beta
        </span>
      </div>
    </SidebarHeader>
  );
}
