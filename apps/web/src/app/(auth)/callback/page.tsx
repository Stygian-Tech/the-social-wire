"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { handleCallback, OAUTH_CALLBACK_TIMEOUT_MS } from "@/lib/auth";
import { consumeOAuthReturnPath } from "@/lib/oauthScopeRecovery";

const WATCHDOG_MS = OAUTH_CALLBACK_TIMEOUT_MS + 15_000;

export default function CallbackPage() {
  const handled = useRef(false);
  const flowFinished = useRef(false);
  const [slowHint, setSlowHint] = useState(false);

  useLayoutEffect(() => {
    // Strict Mode double-invoke guard
    if (handled.current) return;
    handled.current = true;

    handleCallback()
      .then(() => {
        flowFinished.current = true;
        window.location.replace(consumeOAuthReturnPath());
      })
      .catch((err) => {
        flowFinished.current = true;
        console.error("OAuth callback error:", err);
        const message =
          err instanceof Error ? err.message : "OAuth callback failed.";
        window.location.replace(
          `/login?error=callback_failed&message=${encodeURIComponent(
            message.slice(0, 280)
          )}`
        );
      });
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => setSlowHint(true), 5_000);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      if (flowFinished.current) return;
      window.location.replace(
        `/login?error=callback_watchdog&message=${encodeURIComponent(
          `No OAuth callback response after ${WATCHDOG_MS}ms. Try NEXT_PUBLIC_OAUTH_RESPONSE_MODE=query in apps/web/.env.local, then sign in again.`
        )}`
      );
    }, WATCHDOG_MS);
    return () => window.clearTimeout(timer);
  }, []);

  return (
    <div className="flex min-h-[calc(100svh-var(--environment-banner-height,0px))] items-center justify-center bg-background">
      <div className="text-center space-y-3">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent mx-auto" />
        <p className="text-sm text-muted-foreground">Completing Sign-In…</p>
        {slowHint ? (
          <p className="max-w-md text-xs text-muted-foreground">
            Local OAuth now uses query callback params by default. If this keeps
            spinning, wait for the watchdog to return to login with the callback error.
            HMR WebSocket errors are unrelated.
          </p>
        ) : null}
      </div>
    </div>
  );
}
