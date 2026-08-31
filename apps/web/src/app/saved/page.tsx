"use client";

import { SavedLinksBrowser } from "@/components/SavedLinks/SavedLinksBrowser";
import { SembleCollectionBrowser } from "@/components/SavedLinks/SembleCollectionBrowser";
import { useConfiguredReadLaterService } from "@/hooks/useReadLaterPreferences";
import { Suspense } from "react";

export default function SavedPage() {
  const configured = useConfiguredReadLaterService();
  if (configured.isLoading) return null;
  if (configured.serviceId === "semble") {
    return configured.sembleConnection ? (
      <SembleCollectionBrowser connection={configured.sembleConnection} />
    ) : (
      <div className="flex flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground">
        Choose a Semble collection in Your Account settings.
      </div>
    );
  }
  return (
    <Suspense fallback={null}>
      <SavedLinksBrowser mode="active" />
    </Suspense>
  );
}
