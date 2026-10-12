"use client";

import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useSearchParams } from "next/navigation";
import { useAuth } from "@/hooks/useAuth";
import { useBrandAccounts } from "@/hooks/useBrandAccounts";
import { linkBrandAccount, unlinkBrandAccount } from "@/lib/brandAccounts/brandAccountSessions";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { BrandAccountViewer } from "./BrandAccountViewer";
import { BrandAccountSidebarRow } from "./BrandAccountSidebarRow";

export function BrandAccountsWorkspace() {
  const { session } = useAuth();
  return session ? <BrandAccountsManager key={session.did} ownerDid={session.did} /> : <p className="p-6">Log In to Manage Brand Accounts.</p>;
}

function BrandAccountsManager({ ownerDid }: { ownerDid: string }) {
  const cache = useQueryClient();
  const callbackFailed = useSearchParams()?.get("error") === "callback_failed";
  const accounts = useBrandAccounts(ownerDid);
  const [selected, setSelected] = useState<string>();
  const [handle, setHandle] = useState("");
  const [linkOpen, setLinkOpen] = useState(false);
  const [unlink, setUnlink] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const acting = selected && accounts.includes(selected) ? selected : undefined;
  async function connect() {
    if (busy || !handle.trim()) return;
    setBusy(true); setError(undefined);
    try { await linkBrandAccount(ownerDid, handle.trim().replace(/^@/, "")); setLinkOpen(false); setHandle(""); }
    catch (failure) { setError(failure instanceof Error ? failure.message : "The Brand Account Could Not Be Linked."); }
    finally { setBusy(false); }
  }
  async function disconnect() {
    if (busy || !unlink) return;
    const did = unlink;
    // Unmount actor operations before revoking or removing its credentials.
    setSelected(undefined); setBusy(true); setError(undefined);
    try { await cache.cancelQueries({ queryKey: ["brandAccounts", ownerDid, did] }); cache.removeQueries({ queryKey: ["brandAccounts", ownerDid, did] }); await unlinkBrandAccount(ownerDid, did); setUnlink(undefined); }
    catch (failure) { setError(failure instanceof Error ? failure.message : "The Brand Account Could Not Be Removed."); }
    finally { setBusy(false); }
  }
  return <div data-analytics-ignore className="flex min-h-0 min-w-0 flex-1 flex-col">
    <FeedHeader title="Brand Accounts" subtitle="Manage Bluesky Accounts Without Switching Your Personal Account"><Button size="sm" disabled={busy} onClick={() => { setHandle(""); setError(undefined); setLinkOpen(true); }}>Link Account</Button></FeedHeader>
    {callbackFailed ? <p role="alert" className="mx-4 rounded-xl border p-3 text-sm">Brand Account Authorization Failed. Select Link Account to Try Again.</p> : null}
    <div className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-4 lg:flex-row lg:overflow-hidden">
      <aside className="shrink-0 space-y-3 rounded-2xl border p-3 lg:w-64 lg:overflow-y-auto" aria-label="Linked Brand Accounts">{!accounts.length ? <p className="py-6 text-center text-sm text-muted-foreground">No Brand Accounts Linked Yet</p> : accounts.map(did => <BrandAccountSidebarRow key={did} did={did} selected={acting === did} disabled={busy} onSelect={() => setSelected(did)} onUnlink={() => { setError(undefined); setUnlink(did); }} />)}{error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}</aside>
      <section className="min-h-0 min-w-0 flex-1 overflow-y-auto">{acting ? <BrandAccountViewer key={`${ownerDid}:${acting}`} ownerDid={ownerDid} brandDid={acting} /> : <p className="p-8 text-center text-muted-foreground">Select a Linked Account or Link a Brand Account to Begin.</p>}</section>
    </div>
    <Dialog open={linkOpen} onOpenChange={value => { if (!busy) setLinkOpen(value); }}><DialogContent showCloseButton={!busy}><DialogTitle>Link Brand Account</DialogTitle><DialogDescription>Authorize the Brand Account in the Login Flow. Your Personal Account Will Stay Signed In.</DialogDescription><form className="space-y-3" onSubmit={event => { event.preventDefault(); void connect(); }}><label className="block text-sm">Handle or DID<Input aria-label="Brand Account Handle or DID" autoFocus value={handle} onChange={event => setHandle(event.target.value)} disabled={busy} placeholder="brand.bsky.social" /></label>{error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}<div className="flex justify-end gap-2"><DialogClose disabled={busy} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={busy || !handle.trim()}>{busy ? "Authorizing…" : "Authorize Account"}</Button></div></form></DialogContent></Dialog>
    <Dialog open={!!unlink} onOpenChange={value => { if (!value && !busy) setUnlink(undefined); }}><DialogContent showCloseButton={!busy}><DialogTitle>Unlink Brand Account?</DialogTitle><DialogDescription>This Removes Its Linked Session From This Browser and Revokes That Authorization. Your Personal Account Stays Signed In.</DialogDescription><p className="break-all text-sm">{unlink}</p>{error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}<div className="flex justify-end gap-2"><DialogClose disabled={busy} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button variant="destructive" disabled={busy} onClick={() => { void disconnect(); }}>{busy ? "Unlinking…" : "Confirm Unlink"}</Button></div></DialogContent></Dialog>
  </div>;
}
