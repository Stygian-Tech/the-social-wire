"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/hooks/useAuth";
import { AppSidebar } from "@/components/AppSidebar/AppSidebar";
import { PublicationSidebarProvider } from "@/contexts/PublicationSidebarContext";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import {
  SidebarProvider,
  SidebarInset,
  SidebarTrigger,
} from "@/components/ui/sidebar";
import { Separator } from "@/components/ui/separator";

/** Authenticated chrome with publication sidebar — same shell as `/read`. */
export default function SavedLayout({ children }: { children: React.ReactNode }) {
  const { session, isLoading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!isLoading && !session) {
      router.replace("/login");
    }
  }, [isLoading, session, router]);

  if (isLoading) {
    return (
      <div className="flex min-h-[calc(100svh-var(--environment-banner-height,0px))] items-center justify-center">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
      </div>
    );
  }

  if (!session) {
    return null;
  }

  return (
    <SidebarProvider className="h-[calc(100svh-var(--environment-banner-height,0px))] min-h-[calc(100svh-var(--environment-banner-height,0px))] max-h-[calc(100svh-var(--environment-banner-height,0px))] overflow-hidden overscroll-none">
      <PublicationSidebarProvider>
      <ReadRouteProvider>
        <AppSidebar selectedPubId={null} onSelectPub={(pubId) => router.push(`/read/${encodeURIComponent(pubId)}`)} />
        <SidebarInset className="flex min-h-0 flex-1 flex-col overflow-hidden">
          <header className="flex min-h-14 shrink-0 items-center gap-1 border-b bg-background/85 px-2 py-1.5 backdrop-blur-md sm:min-h-12 sm:gap-2 sm:px-3 md:px-4">
            <SidebarTrigger className="h-11 w-11 min-h-[44px] min-w-[44px] shrink-0 -ml-0.5 sm:h-8 sm:w-8 sm:min-h-0 sm:min-w-0 sm:-ml-1" />
            <Separator orientation="vertical" className="h-4" />
            <span className="truncate px-2 text-sm font-semibold text-[var(--purple-foreground)]">
              Read Later
            </span>
          </header>
          <main className="flex min-h-0 flex-1 overflow-hidden">{children}</main>
        </SidebarInset>
      </ReadRouteProvider>
      </PublicationSidebarProvider>
    </SidebarProvider>
  );
}
