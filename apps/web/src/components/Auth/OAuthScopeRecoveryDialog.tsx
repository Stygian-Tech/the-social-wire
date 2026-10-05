"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

type Props = { open: boolean; onOpenChange: (open: boolean) => void; onSignIn: () => Promise<void> };
export function OAuthScopeRecoveryDialog({ open, onOpenChange, onSignIn }: Props) {
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  // AuthProvider mounts this dialog on each request, resetting state on open.
  const signIn = async () => {
    setPending(true);
    setFailed(false);
    try { await onSignIn(); } catch { setPending(false); setFailed(true); }
  };
  return <Dialog open={open} onOpenChange={onOpenChange}>
    <DialogContent>
      <DialogHeader><DialogTitle>Log In Again</DialogTitle><DialogDescription>{SCOPE_RECOVERY_MESSAGE} Your current account remains signed in until you choose to continue.</DialogDescription></DialogHeader>
      {failed && <p role="alert" className="text-sm text-destructive">Couldn’t Start Login. Please Try Again.</p>}
      <DialogFooter><DialogClose render={<Button variant="outline" disabled={pending} />}>Cancel</DialogClose><Button disabled={pending} onClick={() => void signIn()}>{pending ? "Opening Login…" : "Log In Again"}</Button></DialogFooter>
    </DialogContent>
  </Dialog>;
}
