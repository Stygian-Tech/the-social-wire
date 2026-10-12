"use client";

import { useEffect, useState } from "react";
import { Agent } from "@atproto/api";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";

/** Labels are public account metadata; account OAuth credentials are never sent here. */
export function AnalyticsAccountIdentity({ did, personal = false }: { did: string; personal?: boolean }) {
  const [profile, setProfile] = useState<{ did: string; handle: string; name?: string }>();
  useEffect(() => {
    const controller = new AbortController();
    const agent = new Agent(getAtprotoNetwork().publicAppView);
    void agent.getProfile({ actor: did }, { signal: controller.signal }).then(({ data }) => {
      if (!controller.signal.aborted && data.did === did) setProfile({ did, handle: data.handle, name: data.displayName });
    }).catch(() => { /* DID remains a useful identity when metadata is unavailable. */ });
    return () => controller.abort();
  }, [did]);
  const current = profile?.did === did ? profile : undefined;
  return <span className="min-w-0 break-all" title={did}>{current ? `${current.name || current.handle} (@${current.handle})` : personal ? "Personal Account" : did}{current && personal ? " · Personal" : ""}</span>;
}
