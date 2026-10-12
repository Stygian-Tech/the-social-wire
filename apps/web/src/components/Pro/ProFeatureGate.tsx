"use client";

import { useProEntitlements } from "@/hooks/useProEntitlements";
import { Button } from "@/components/ui/button";

export function ProFeatureGate({ children }: { children: React.ReactNode }) {
  const access = useProEntitlements();
  if (access.isPro) return children;
  return <section className="flex w-full flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
    {access.isPending ? <p role="status">Checking Pro Access…</p> : <>
      <h1 className="text-xl font-semibold">Social Wire Pro</h1>
      <p className="max-w-md text-sm text-muted-foreground">{access.isError ? "Pro access could not be verified. Please retry." : "Tools and multi-account support are available with Pro. Subscriptions are coming soon."}</p>
      <Button variant="outline" disabled={access.isFetching} onClick={() => { void access.refetch(); }}>Retry Pro Access</Button>
    </>}
  </section>;
}
