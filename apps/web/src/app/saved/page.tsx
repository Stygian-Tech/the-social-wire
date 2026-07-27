"use client";

import { SavedLinksBrowser } from "@/components/SavedLinks/SavedLinksBrowser";
import { Suspense } from "react";

export default function SavedPage() {
  return (
    <Suspense fallback={null}>
      <SavedLinksBrowser mode="active" />
    </Suspense>
  );
}
