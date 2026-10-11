"use client";

import { useQuery } from "@tanstack/react-query";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { getBrandAccountPublicProfile } from "@/lib/brandAccounts/brandAccountPublicProfile";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";

export function BrandAccountSidebarRow({ did, selected, disabled, onSelect, onUnlink }: { did: string; selected: boolean; disabled: boolean; onSelect: () => void; onUnlink: () => void }) {
  const appView = getAtprotoNetwork().publicAppView;
  const query = useQuery({ queryKey: ["brandPublicProfile", did, appView], queryFn: ({ signal }) => getBrandAccountPublicProfile(did, appView, signal), staleTime: 5 * 60_000, retry: false });
  const profile = !query.isError && query.data?.did === did ? query.data : undefined;
  const name = profile?.displayName || profile?.handle || "Linked Brand Account";
  return <div className="space-y-1">
    <button disabled={disabled} aria-pressed={selected} aria-label={`Select Brand Account: ${profile ? `${name} @${profile.handle} · ` : ""}${did}`} title={did} className={`flex w-full min-w-0 items-center gap-2 rounded-xl p-2 text-left text-sm ${selected ? "bg-accent" : "hover:bg-accent"}`} onClick={onSelect}>
      <Avatar src={profile?.avatar} alt={name} size={36} className="shrink-0" />
      <span className="min-w-0 flex-1"><span className="block truncate font-medium">{name}</span><span className="block truncate text-xs text-muted-foreground">{profile ? `@${profile.handle}` : query.isPending ? "Loading Profile…" : "Profile Unavailable"}</span></span>
    </button>
    <Button size="sm" variant="ghost" disabled={disabled} onClick={onUnlink}>Unlink Account</Button>
  </div>;
}
