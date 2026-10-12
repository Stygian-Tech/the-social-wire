"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { rememberOAuthReturnPath } from "@/lib/oauthScopeRecovery";

export function SocialPermissionRecovery() {
  const { session, signIn } = useAuth();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(false);
  async function recover() {
    if (!session) return;
    setPending(true); setError(false); rememberOAuthReturnPath();
    try { await signIn(session.did); } catch { setPending(false); setError(true); }
  }
  return <div className="mt-2 space-y-2"><Button size="sm" disabled={pending || !session} onClick={() => { void recover(); }}>{pending ? "Opening Login…" : "Log In Again"}</Button>{error ? <p role="alert" className="text-xs text-destructive">Login could not be opened. Please try again.</p> : null}</div>;
}
