"use client";
import { Suspense, useEffect } from "react";
import { useRouter } from "next/navigation";
import { usePodcastViewer } from "@/hooks/usePodcastViewer";
import { useAuth } from "@/hooks/useAuth";
import { PodcastContentPane } from "@/components/Podcasts/PodcastContentPane";
import { appViewportHeightClasses, appMobileNavigationPaddingClasses } from "@/components/shared/appViewportStyles";
import { AppSidebar } from "@/components/AppSidebar/AppSidebar";
import { PublicationSidebarProvider } from "@/contexts/PublicationSidebarContext";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import { SidebarProvider, SidebarInset } from "@/components/ui/sidebar";
export default function PodcastsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const { session, isLoading } = useAuth();
  const viewer = usePodcastViewer();
  const router = useRouter();
  useEffect(() => {
    if (!isLoading && !session && !viewer) router.replace("/login");
  }, [isLoading, session, viewer, router]);
  if (isLoading && !viewer)
    return (
      <p role="status" className="p-6">
        Loading Podcasts…
      </p>
    );
  if (!viewer) return null;
  return (
    <SidebarProvider className={`mx-auto ${appViewportHeightClasses} max-w-[80rem] overflow-hidden [--reader-shell-width:80rem]`}>
      <PublicationSidebarProvider>
        <ReadRouteProvider>
          <Suspense fallback={null}>
            <AppSidebar
              selectedPubId={null}
              showPublicationsRail={false}
              onSelectPub={(id) =>
                router.push(`/read/${encodeURIComponent(id)}`)
              }
            />
          </Suspense>
          <SidebarInset className={`min-h-0 overflow-hidden ${appMobileNavigationPaddingClasses}`}>
            <PodcastContentPane>{children}</PodcastContentPane>
          </SidebarInset>
        </ReadRouteProvider>
      </PublicationSidebarProvider>
    </SidebarProvider>
  );
}
