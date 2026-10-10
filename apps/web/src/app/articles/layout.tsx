"use client";

import { Suspense, useEffect } from "react";
import { useRouter } from "next/navigation";
import { AppSidebar } from "@/components/AppSidebar/AppSidebar";
import { PublicationSidebarProvider } from "@/contexts/PublicationSidebarContext";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import { useAuth } from "@/hooks/useAuth";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { appMobileNavigationPaddingClasses, appViewportHeightClasses } from "@/components/shared/appViewportStyles";

export default function ArticlesLayout({ children }: { children: React.ReactNode }) {
  const { session, isLoading } = useAuth();
  const router = useRouter();
  useEffect(() => { if (!isLoading && !session) router.replace("/login"); }, [isLoading, session, router]);
  if (isLoading) return <div className="flex min-h-svh items-center justify-center"><p role="status">Loading Articles…</p></div>;
  if (!session) return null;
  return <SidebarProvider className={`mx-auto ${appViewportHeightClasses} max-w-[80rem] overflow-hidden [--reader-shell-width:80rem]`}>
    <PublicationSidebarProvider><ReadRouteProvider>
      <Suspense fallback={null}><AppSidebar selectedPubId={null} onSelectPub={id => router.push(`/read/${encodeURIComponent(id)}`)} showPublicationsRail={false} /></Suspense>
      <SidebarInset className={`flex min-h-0 flex-1 flex-col overflow-hidden ${appMobileNavigationPaddingClasses}`}><main className="flex min-h-0 min-w-0 flex-1 overflow-hidden">{children}</main></SidebarInset>
    </ReadRouteProvider></PublicationSidebarProvider>
  </SidebarProvider>;
}
