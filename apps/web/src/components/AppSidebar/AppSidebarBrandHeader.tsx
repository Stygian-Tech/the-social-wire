"use client";

import Image from "next/image";

import { SidebarHeader } from "@/components/ui/sidebar";

export function AppSidebarBrandHeader() {
  return (
    <SidebarHeader className="px-2 py-3">
      <div className="grid min-w-0 grid-cols-[1.5rem_auto] items-center gap-x-1.5">
        <Image
          src="/icons/social-wire-icon-light-192.png"
          alt=""
          width={24}
          height={24}
          className="col-start-1 row-start-1 shrink-0 rounded dark:hidden"
        />
        <Image
          src="/icons/social-wire-icon-dark-192.png"
          alt=""
          width={24}
          height={24}
          className="col-start-1 row-start-1 hidden shrink-0 rounded dark:block"
        />
        <span className="col-start-2 whitespace-nowrap text-[13px] font-bold leading-tight tracking-[-0.02em] text-sidebar-foreground">
          The Social Wire
        </span>
      </div>
    </SidebarHeader>
  );
}
