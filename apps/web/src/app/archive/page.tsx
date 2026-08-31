"use client";

import { SavedLinksBrowser } from "@/components/SavedLinks/SavedLinksBrowser";
import { useConfiguredReadLaterService } from "@/hooks/useReadLaterPreferences";
import { useRouter } from "next/navigation";
import { Suspense, useEffect } from "react";

export default function ArchivePage() {
  const router = useRouter();
  const configured = useConfiguredReadLaterService();
  useEffect(() => {
    if (!configured.isLoading && configured.serviceId === "semble") {
      router.replace("/saved");
    }
  }, [configured.isLoading, configured.serviceId, router]);
  if (configured.isLoading || configured.serviceId === "semble") return null;
  return (
    <Suspense fallback={null}>
      <SavedLinksBrowser mode="archived" />
    </Suspense>
  );
}
