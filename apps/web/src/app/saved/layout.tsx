"use client";

import { Suspense, useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/hooks/useAuth";
import { AppSidebar } from "@/components/AppSidebar/AppSidebar";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { PublicationSidebarProvider } from "@/contexts/PublicationSidebarContext";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import {
  SidebarProvider,
  SidebarInset,
} from "@/components/ui/sidebar";

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
    <SidebarProvider defaultWidthPx={208} className="mx-auto h-[calc(100svh-var(--environment-banner-height,0px))] min-h-[calc(100svh-var(--environment-banner-height,0px))] max-h-[calc(100svh-var(--environment-banner-height,0px))] max-w-[70rem] overflow-hidden overscroll-none">
      <PublicationSidebarProvider>
      <ReadRouteProvider>
        <Suspense fallback={null}>
          <AppSidebar selectedPubId={null} onSelectPub={(pubId) => router.push(`/read/${encodeURIComponent(pubId)}`)} />
        </Suspense>
        <SidebarInset className="flex min-h-0 flex-1 flex-col overflow-hidden pb-16 md:pb-0 lg:mr-64">
          <FeedHeader title="Read Later" />
          <main className="flex min-h-0 flex-1 overflow-hidden">{children}</main>
        </SidebarInset>
      </ReadRouteProvider>
      </PublicationSidebarProvider>
    </SidebarProvider>
  );
}
