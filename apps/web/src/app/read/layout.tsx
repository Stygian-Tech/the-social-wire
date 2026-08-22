"use client";

import { Suspense, useEffect } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/hooks/useAuth";
import { AppSidebar } from "@/components/AppSidebar/AppSidebar";
import { PublicationSidebarProvider } from "@/contexts/PublicationSidebarContext";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import { ReadSidebarScopeProvider } from "@/contexts/ReadSidebarScopeContext";
import {
  SidebarProvider,
  SidebarInset,
} from "@/components/ui/sidebar";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import { ReadArticleFilterBar } from "@/app/read/ReadArticleFilterBar";
import { ClosePublicationsSheetOnMobilePubRoute } from "@/app/read/ClosePublicationsSheetOnMobilePubRoute";
import { isWireNewsEditionEnabled } from "@/lib/wireEditionClient";

export default function ReadLayout({
  children,
}: {
  children: React.ReactNode;
}) {
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
    <SidebarProvider
      defaultWidthPx={208}
      className="mx-auto h-[calc(100svh-var(--environment-banner-height,0px))] min-h-[calc(100svh-var(--environment-banner-height,0px))] max-h-[calc(100svh-var(--environment-banner-height,0px))] max-w-[var(--reader-shell-width)] overflow-hidden overscroll-none [--reader-shell-width:70rem] has-[[data-wire-route=true]]:[--reader-shell-width:82rem]"
    >
      <PublicationSidebarProvider>
        <ReadRouteProvider>
          <ReadSidebarScopeProvider>
            <ClosePublicationsSheetOnMobilePubRoute
              selectedPubId={selectedPubId}
            />
            <Suspense fallback={null}>
              <AppSidebar
                selectedPubId={selectedPubId}
                onSelectPub={(pubId) =>
                  router.push(`/read/${encodeURIComponent(pubId)}`)
                }
              />
            </Suspense>
            <Suspense
              fallback={
                <SidebarInset className="flex min-h-0 flex-1 flex-col overflow-hidden pb-16 md:pb-0">
                  <main className="flex min-h-0 flex-1 overflow-hidden">
                    {children}
                  </main>
                </SidebarInset>
              }
            >
              <ReadContentInset>{children}</ReadContentInset>
            </Suspense>
          </ReadSidebarScopeProvider>
        </ReadRouteProvider>
      </PublicationSidebarProvider>
    </SidebarProvider>
  );
}

function ReadContentInset({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const wireRoute =
    pathname === "/read" && searchParams.get("feed") === "wire";
  const wireNewsRoute = wireRoute && isWireNewsEditionEnabled();

  return (
    <SidebarInset
      data-wire-route={wireNewsRoute ? "true" : undefined}
      className={`flex min-h-0 flex-1 flex-col overflow-hidden pb-16 md:pb-0 ${wireRoute ? "" : "lg:mr-64"}`}
    >
      <ReadArticleFilterBar />
      <main className="flex min-h-0 flex-1 overflow-hidden">{children}</main>
    </SidebarInset>
  );
}
