"use client";

import { useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useBrandAccounts } from "@/hooks/useBrandAccounts";
import { SocialComposeAccountPicker } from "@/components/Social/SocialComposeAccountPicker";
import { ContentCalendarAccount } from "./ContentCalendarAccount";

export function ContentCalendarWorkspace() {
  const { session } = useAuth();
  return session ? <AccountCalendarWorkspace key={session.did} ownerDid={session.did} /> : null;
}
function AccountCalendarWorkspace({ ownerDid }: { ownerDid: string }) {
  const accounts = useBrandAccounts(ownerDid);
  const [actorDid, setActorDid] = useState(ownerDid);
  return <section data-analytics-ignore className="flex min-h-0 w-full flex-col overflow-y-auto p-3 sm:p-4">
    <header className="floating-glass mb-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl border p-3"><h1 className="text-xl font-semibold">Content Calendar</h1><div className="w-full max-w-sm"><SocialComposeAccountPicker label="Account" ownerDid={ownerDid} accounts={accounts} actorDid={actorDid} disabled={false} onChange={setActorDid} /></div></header>
    {actorDid !== ownerDid && !accounts.includes(actorDid) ? <p role="alert" className="py-6 text-center text-sm text-muted-foreground">This Brand Account Is No Longer Linked.</p> : <ContentCalendarAccount key={`${ownerDid}:${actorDid}`} ownerDid={ownerDid} actorDid={actorDid} />}
  </section>;
}
