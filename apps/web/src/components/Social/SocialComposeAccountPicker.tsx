"use client";

import { useQueries } from "@tanstack/react-query";
import { ChevronDown } from "lucide-react";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { getBrandAccountPublicProfile } from "@/lib/brandAccounts/brandAccountPublicProfile";
import { Avatar } from "@/components/shared/Avatar";

export function SocialComposeAccountPicker({ ownerDid, accounts, actorDid, disabled, onChange, label = "Post As" }: { label?: string; ownerDid: string; accounts: string[]; actorDid: string; disabled: boolean; onChange: (did: string) => void }) {
  const appView = getAtprotoNetwork().publicAppView;
  const dids = [ownerDid, ...accounts.filter(did => did !== ownerDid)];
  const queries = useQueries({ queries: dids.map(did => ({ queryKey: ["brandPublicProfile", did, appView], queryFn: ({ signal }: { signal: AbortSignal }) => getBrandAccountPublicProfile(did, appView, signal), staleTime: 300_000, retry: false })) });
  const identities = dids.map((did, index) => { const query = queries[index]; return !query.isError && query.data?.did === did ? query.data : undefined; });
  const selected = identities[dids.indexOf(actorDid)];
  return <div className="flex min-w-0 items-center gap-2">
    <Avatar src={selected?.avatar} alt="" size={36} className="shrink-0" />
    <div className="min-w-0 flex-1"><label htmlFor="social-compose-account" className="mb-1 block text-xs text-muted-foreground">{label}</label><div className="relative"><select id="social-compose-account" value={actorDid} disabled={disabled} onChange={event => onChange(event.target.value)} className="w-full min-w-0 appearance-none truncate rounded-xl border bg-background py-2 pl-3 pr-9 text-sm">
      {dids.map((did, index) => <option key={did} value={did}>{identities[index] ? `${identities[index]!.displayName || identities[index]!.handle} @${identities[index]!.handle}` : did === ownerDid ? "Personal Account" : `Linked Brand Account ${index}`}</option>)}
      {!dids.includes(actorDid) ? <option value={actorDid}>Unlinked Brand Account</option> : null}
    </select><ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2" /></div></div>
  </div>;
}
