"use client";

import { BrandAccountViewer } from "@/components/BrandAccounts/BrandAccountViewer";

/** Each recipient owns its session, moderation, paging, and interaction guards. */
export function BrandNotificationSections({ ownerDid, accounts, included, setIncluded, onUnread }: { ownerDid: string; accounts: string[]; included: boolean; setIncluded: (value: boolean) => void; onUnread: (did: string, count: number | undefined) => void }) {
  if (!accounts.length) return null;
  return <section aria-label="Linked Brand Notifications" className="space-y-4">
    <label className="flex cursor-pointer items-center gap-2 text-sm"><input type="checkbox" checked={included} onChange={event => setIncluded(event.target.checked)} />Include Brand Accounts</label>
    {included ? accounts.map(did => <section key={`${ownerDid}:${did}`} aria-label={`Notifications for Brand ${did}`}><BrandAccountViewer ownerDid={ownerDid} brandDid={did} notificationsOnly onUnread={onUnread} /></section>) : null}
  </section>;
}
