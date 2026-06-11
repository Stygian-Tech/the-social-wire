"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useAuth } from "@/hooks/useAuth";
import { AppSidebar } from "@/components/AppSidebar/AppSidebar";
import { PublicationSidebarProvider } from "@/contexts/PublicationSidebarContext";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import { ReadSidebarScopeProvider } from "@/contexts/ReadSidebarScopeContext";
import {
  SidebarProvider,
  SidebarInset,
  SidebarTrigger,
  useSidebar,
} from "@/components/ui/sidebar";
import { Separator } from "@/components/ui/separator";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import { ReadArticleFilterBar } from "@/app/read/ReadArticleFilterBar";

function ClosePublicationsSheetOnMobilePubRoute({
  selectedPubId,
}: {
  selectedPubId: string | null;
}) {
  const { isMobile, setOpenMobile } = useSidebar();

  useEffect(() => {
    if (isMobile && selectedPubId) {
      setOpenMobile(false);
    }
  }, [isMobile, selectedPubId, setOpenMobile]);

  return null;
}

export default function ReadLayout({ children }: { children: React.ReactNode }) {
  const { session, isLoading } = useAuth();
  const router = useRouter();
  const pathname = usePathname();

  // Derive the selected pubId from the URL path: /read/[...pubId] (joined suffix)
  const selectedPubId = pathname.startsWith("/read/")
    ? normalizeAtRepoParam(pathname.slice("/read/".length))
    : null;

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
    // Redirect in progress; render nothing to avoid flash
    return null;
  }

  return (
    <SidebarProvider className="h-[calc(100svh-var(--environment-banner-height,0px))] min-h-[calc(100svh-var(--environment-banner-height,0px))] max-h-[calc(100svh-var(--environment-banner-height,0px))] overflow-hidden overscroll-none">
      <PublicationSidebarProvider>
      <ReadRouteProvider>
        <ReadSidebarScopeProvider>
          <ClosePublicationsSheetOnMobilePubRoute selectedPubId={selectedPubId} />
          <AppSidebar
            selectedPubId={selectedPubId}
            onSelectPub={(pubId) => router.push(`/read/${encodeURIComponent(pubId)}`)}
          />
          <SidebarInset className="flex min-h-0 flex-1 flex-col overflow-hidden">
            <header className="flex h-11 min-h-11 shrink-0 items-center gap-2 border-b px-2 sm:h-10 sm:min-h-10 sm:gap-2 sm:px-3 md:px-4">
              <SidebarTrigger className="h-11 w-11 min-h-[44px] min-w-[44px] shrink-0 -ml-0.5 sm:h-8 sm:w-8 sm:min-h-0 sm:min-w-0 sm:-ml-1" />
              <Separator orientation="vertical" className="h-4" />
              <ReadArticleFilterBar />
            </header>
            <main className="flex min-h-0 flex-1 overflow-hidden">{children}</main>
          </SidebarInset>
        </ReadSidebarScopeProvider>
      </ReadRouteProvider>
      </PublicationSidebarProvider>
    </SidebarProvider>
  );
}
