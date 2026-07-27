"use client";

import { SavedLinksBrowser } from "@/components/SavedLinks/SavedLinksBrowser";
import { Suspense } from "react";

export default function ArchivePage() {
  return (
    <Suspense fallback={null}>
      <SavedLinksBrowser mode="archived" />
    </Suspense>
  );
}
