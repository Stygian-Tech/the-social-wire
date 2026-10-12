"use client";

import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
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
  return <section data-analytics-ignore className="flex min-h-0 w-full flex-1 flex-col overflow-hidden">
    <FeedHeader title="Content Calendar"><div className="w-full max-w-sm"><SocialComposeAccountPicker label="Account" ownerDid={ownerDid} accounts={accounts} actorDid={actorDid} disabled={false} onChange={setActorDid} /></div></FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-4 pt-0">
    {actorDid !== ownerDid && !accounts.includes(actorDid) ? <p role="alert" className="py-6 text-center text-sm text-muted-foreground">This Brand Account Is No Longer Linked.</p> : <ContentCalendarAccount key={`${ownerDid}:${actorDid}`} ownerDid={ownerDid} actorDid={actorDid} />}
    </div>
  </section>;
}
