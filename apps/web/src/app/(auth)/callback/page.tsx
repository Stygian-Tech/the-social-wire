"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { handleCallback } from "@/lib/auth";

export default function CallbackPage() {
  const router = useRouter();
  const handled = useRef(false);

  useEffect(() => {
    // Strict Mode double-invoke guard
    if (handled.current) return;
    handled.current = true;

    handleCallback()
      .then(() => {
        router.replace("/read");
      })
      .catch((err) => {
        console.error("OAuth callback error:", err);
        router.replace("/login?error=callback_failed");
      });
  }, [router]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background">
      <div className="text-center space-y-3">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent mx-auto" />
        <p className="text-sm text-muted-foreground">Completing sign-in…</p>
      </div>
    </div>
  );
}
