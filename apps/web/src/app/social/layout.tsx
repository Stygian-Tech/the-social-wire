"use client";

import { Suspense, useEffect } from "react";
import {
  appMobileNavigationPaddingClasses,
  appViewportHeightClasses,
} from "@/components/shared/appViewportStyles";
import { useRouter } from "next/navigation";
import { AppSidebar } from "@/components/AppSidebar/AppSidebar";
import { PublicationSidebarProvider } from "@/contexts/PublicationSidebarContext";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import { useAuth } from "@/hooks/useAuth";
import { SocialFeeds } from "@/components/Social/SocialFeeds";
import { floatingSidebarClassName } from "@/components/shared/floatingSidebarStyles";
import {
  SidebarInset,
  SidebarProvider,
} from "@/components/ui/sidebar";

export default function SocialLayout({ children }: { children: React.ReactNode }) {
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
    <SidebarProvider className={`mx-auto ${appViewportHeightClasses} max-w-[80rem] overflow-hidden overscroll-none [--reader-shell-width:80rem]`}>
      <PublicationSidebarProvider>
        <ReadRouteProvider>
          <Suspense fallback={null}>
            <AppSidebar
              selectedPubId={null}
              onSelectPub={(pubId) =>
                router.push(`/read/${encodeURIComponent(pubId)}`)
              }
              showPublicationsRail={false}
            />
          </Suspense>
          <SidebarInset className={`flex min-h-0 flex-1 flex-col overflow-hidden ${appMobileNavigationPaddingClasses}`}>
            <div className="flex min-h-0 flex-1 overflow-hidden">
              <main className="flex min-h-0 min-w-0 flex-1 overflow-hidden">{children}</main>
              <aside aria-label="Social Feed Sidebar" className="hidden w-60 shrink-0 overflow-y-auto overscroll-contain p-3 lg:block">
                <div className={floatingSidebarClassName}>
                  <h2 className="mb-2 px-2 text-sm font-semibold">Feeds</h2>
                  <Suspense fallback={null}><SocialFeeds /></Suspense>
                </div>
              </aside>
            </div>
          </SidebarInset>
        </ReadRouteProvider>
      </PublicationSidebarProvider>
    </SidebarProvider>
  );
}
