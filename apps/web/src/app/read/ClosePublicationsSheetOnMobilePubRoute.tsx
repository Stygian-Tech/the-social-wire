"use client";

import { useEffect } from "react";
import { useSidebar } from "@/components/ui/sidebar";

export function ClosePublicationsSheetOnMobilePubRoute({
  selectedPubId,
}: {
  selectedPubId: string | null;
}) {
  const { isMobile, setOpenMobile } = useSidebar();
  useEffect(() => {
    if (isMobile && selectedPubId) setOpenMobile(false);
  }, [isMobile, selectedPubId, setOpenMobile]);
  return null;
}
